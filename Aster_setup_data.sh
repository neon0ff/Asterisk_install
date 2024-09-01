#!/bin/bash -e

# Функции для цветного вывода сообщений
print_success() {
    echo -e "\033[0;32m$1\033[0m"
}

print_warning() {
    echo -e "\033[0;33m$1\033[0m"
}

print_error() {
    echo -e "\033[0;31m$1\033[0m"
}

# Функция для чтения данных из файла
read_data_from_file() {
    echo -n "Введите путь к файлу с данными: "
    read file_path
    if [ ! -f "$file_path" ]; then
        print_error "Файл не найден."
        exit 1
    fi

    server=$(head -n 1 "$file_path")
    mapfile -t accounts < <(tail -n +2 "$file_path")
}

# Функция для чтения данных через токен
read_data_from_token() {
    echo -n "Введите токен Plusofon: "
    read plusofon_token

    echo -n "Введите номер Астериска: "
    read AsterNumber

    response=$(curl -s -X GET \
        -G "https://restapi.plusofon.ru/api/v1/sip" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Client: 10553" \
        -H "Authorization: Bearer $plusofon_token")

    echo "Доступные SIP аккаунты:"
    echo "$response" | jq -r '.data[] | "\(.id) - \(.name) (\(.login))"'

    echo "Введите начальный и конечный ID SIP аккаунтов через пробел (например, 19225 21677):"
    read start_id end_id

    available_ids=($(echo "$response" | jq -r '.data[].id'))

    filtered_ids=()
    for id in "${available_ids[@]}"; do
        if (( id >= start_id && id <= end_id )); then
            filtered_ids+=("$id")
        fi
    done

    accounts=()
    for id in "${filtered_ids[@]}"; do
        sip_detail=$(curl -s -X GET \
            -G "https://restapi.plusofon.ru/api/v1/sip/$id" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "Client: 10553" \
            -H "Authorization: Bearer $plusofon_token")

        success=$(echo "$sip_detail" | jq -r '.success')
        if [ "$success" != "true" ]; then
            print_warning "SIP ID: $id не найден или не существует."
            continue
        fi

        login=$(echo "$sip_detail" | jq -r '.login')
        password=$(echo "$sip_detail" | jq -r '.password')
        server=$(echo "$sip_detail" | jq -r '.server')  # Получение сервера из ответа
        accounts+=("$login:$password:$server")
    done
}

# Выбор способа ввода данных
echo "Выберите способ ввода данных:"
echo "1) Через токен Plusofon"
echo "2) Из файла"
read -p "Ваш выбор (1 или 2): " choice

case $choice in
    1)
        read_data_from_token
        ;;
    2)
        read_data_from_file
        ;;
    *)
        print_error "Неверный выбор."
        exit 1
        ;;
esac

# Пути к файлам конфигурации
pjsip_conf_path="/etc/asterisk/pjsip.conf"
extensions_conf_path="/etc/asterisk/extensions.conf"

# Получение последнего номера для plusofon и SIP из pjsip.conf
last_plusofon=$(grep -oP '\[plusofon\K\d+' "$pjsip_conf_path" | sort -nr | head -n 1)
last_sip=$(grep -oP '\[16\K\d+' "$pjsip_conf_path" | sort -nr | head -n 1)

# Начинаем с следующих номеров
next_plusofon=$((last_plusofon + 1))
next_sip=$((last_sip + 1))

for account in "${accounts[@]}"; do
    login=$(echo $account | cut -d':' -f1)
    password=$(echo $account | cut -d':' -f2)
    server=$(echo $account | cut -d':' -f3)

    plusofon_label="plusofon${next_plusofon}"
    sip_label="16$(printf "%03d" $next_sip)"

    # Проверка существования секции в pjsip.conf
    if grep -q "\[$plusofon_label\]" "$pjsip_conf_path"; then
        print_warning "Секция [$plusofon_label] уже существует в pjsip.conf, пропуск."
        continue
    fi

    # Добавление транка в pjsip.conf
    cat << EOF >> "$pjsip_conf_path"

[$plusofon_label]
type = registration
transport = transport-tcp
outbound_auth = ${plusofon_label}_auth
retry_interval = 5
expiration = 300
auth_rejection_permanent = yes
contact_user = $login
server_uri = sip:$server
client_uri = sip:$login@$server

[${plusofon_label}_auth]
type = auth
auth_type = userpass
password = $password
username = $login

[$plusofon_label]
type = endpoint
transport = transport-tcp
context = from-$plusofon_label
disallow = all
allow = ulaw
outbound_auth = ${plusofon_label}_auth
aors = $plusofon_label
from_domain = $server
from_user = $login
sdp_owner = $login
direct_media = no
ice_support = yes
send_rpid = yes
rtp_symmetric = yes
force_rport = yes
timers = no
webrtc = yes

[$plusofon_label]
type = aor
contact = sip:$login@$server:5060

[$plusofon_label]
type = identify
endpoint = $plusofon_label
match = 185.54.49.80
match = 185.54.49.83

EOF

    # Добавление SIP в pjsip.conf
    cat << EOF >> "$pjsip_conf_path"

[$sip_label]
type=endpoint
aors=$sip_label
auth=${sip_label}-auth
allow=ulaw
context=to-$plusofon_label
callerid=$sip_label
ice_support=yes
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
dtmf_mode=rfc4733
webrtc=yes

[${sip_label}-auth]
type=auth
auth_type=userpass
password=$(openssl rand -base64 12)
username=$sip_label

[$sip_label]
type=aor
max_contacts=5
remove_existing=yes
qualify_frequency=60

EOF

    # Проверка существования секции в extensions.conf
    if grep -q "\[to-$plusofon_label\]" "$extensions_conf_path"; then
        print_warning "Секция [to-$plusofon_label] уже существует в extensions.conf. Пропуск."
        continue
    fi

    # Запись данных в extensions.conf
    cat << EOF >> "$extensions_conf_path"

[to-$plusofon_label]
exten => _X.,1,Gosub(sub-record-check,s,1(out,\${EXTEN},force))
exten => _X.,n,Dial(PJSIP/\${EXTEN}@$plusofon_label)

EOF

    # Инкрементируем номера для следующей итерации
    next_plusofon=$((next_plusofon + 1))
    next_sip=$((next_sip + 1))

done

# Подтверждение изменений и завершение
print_success "Данные успешно добавлены в pjsip.conf и extensions.conf."
