#!/bin/sh -e

# Запрашиваем данные у пользователя
echo -n "Введите домен: "
read domain
echo "Ваш домен: $domain"

echo -n "Введите email для Certbot: "
read email
echo "Ваш email: $email"

echo -n "Введите номер Астериска: "
read AsterNumber
echo "Ваш номер Астериска: $AsterNumber"

# Запрашиваем домен CRM у пользователя
echo -n "Введите домен CRM: "
read crm_domain
echo "Ваш домен CRM: $crm_domain"

# Подтверждение правильности введенных данных
echo "Вы ввели следующие данные:"
echo "Домен: $domain"
echo "Email: $email"
echo -n "Все ли верно? (y/n): "
read confirmation

if [ "$confirmation" != "y" ]; then
    echo "Скрипт был прерван пользователем."
    exit 1
fi

sudo apt update -y
sudo apt install asterisk -y
sudo mkdir /etc/asterisk/keys
sudo chown asterisk:asterisk /etc/asterisk/keys
sudo apt install certbot -y 

# Определяем параметры по умолчанию
output_dir="/etc/asterisk/keys"

# Проверяем наличие необходимых утилит
if ! type certbot >/dev/null 2>&1; then
    echo "Этот скрипт требует установки certbot."
    exit 1
fi

# Создаем директорию, если её нет
sudo mkdir -p "${output_dir}"

# Генерация серверного сертификата
if [ -z "${domain}" ]; then
    echo "Требуется указать домен для серверного сертификата."
    exit 1
fi

echo "Создание серверного SSL сертификата для домена ${domain} с email ${email}."
sudo certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive
if [ $? -ne 0 ]; then
    echo "Не удалось создать серверный сертификат."
    exit 1
fi

# Копирование сертификатов в нужную директорию
cert_path="/etc/letsencrypt/live/${domain}"
sudo cp "${cert_path}/fullchain.pem" "${output_dir}/asterisk.crt"
sudo cp "${cert_path}/privkey.pem" "${output_dir}/asterisk.key"
cat "${cert_path}/privkey.pem" "${cert_path}/fullchain.pem" > "${output_dir}/asterisk.pem"

echo "Серверный сертификат успешно создан и сохранен в ${output_dir}."

# Выдача права на сертификаты Астериску
sudo chown asterisk:asterisk asterisk*

# Заменяем содержимое файла /etc/asterisk/http.conf
cat << EOF > /etc/asterisk/http.conf
; Asterisk Built-in mini-HTTP server
[general]
servername=Asterisk
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes          ; enable tls - default no.
tlsbindaddr=0.0.0.0:8089    ; address and port to bind to - default is bindaddr and port 8089.
tlscertfile=/etc/asterisk/keys/asterisk.pem  ; path to the certificate file (*.pem) only.
tlsprivatekey=/etc/asterisk/keys/asterisk.key    ; path to private key file (*.pem) only.
tlscafile=/etc/asterisk/keys/ca.crt
EOF

echo "Файл /etc/asterisk/http.conf был успешно обновлен."

# Выбор настроек под ооператора 
# echo "Выберете оператора:"
# echo "1) Plusofon"
# echo "2) Mango"
# read operator
# if operator = 1

# Переименовываем существующий файл pjsip.conf
if [ -f /etc/asterisk/pjsip.conf ]; then
    sudo mv /etc/asterisk/pjsip.conf /etc/asterisk/pjsip.conf_backup
    echo "Файл /etc/asterisk/pjsip.conf был переименован в /etc/asterisk/pjsip.conf_backup."
else
    echo "Файл /etc/asterisk/pjsip.conf не найден, пропускаем переименование."
fi

# Скачиваем новый файл pjsip.conf с GitHub
sudo curl -o /etc/asterisk/pjsip.conf https://raw.githubusercontent.com/neon0ff/Asterisk_install/main/pjsip.conf

if [ $? -eq 0 ]; then
    echo "Новый файл pjsip.conf успешно загружен и сохранен в /etc/asterisk."
else
    echo "Ошибка при загрузке файла pjsip.conf."
    exit 1
fi

# Переименовываем существующий файл extensions.conf
if [ -f /etc/asterisk/extensions.conf ]; then
    sudo mv /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf_backup
    echo "Файл /etc/asterisk/extensions.conf был переименован в /etc/asterisk/extensions.conf_backup."
else
    echo "Файл /etc/asterisk/extensions.conf не найден, пропускаем переименование."
fi

# Скачиваем новый файл extensions.conf с GitHub
sudo curl -o /etc/asterisk/extensions.conf https://raw.githubusercontent.com/neon0ff/Asterisk_install/main/extensions.conf

if [ $? -eq 0 ]; then
    echo "Новый файл extensions.conf успешно загружен и сохранен в /etc/asterisk."
else
    echo "Ошибка при загрузке файла extensions.conf."
    exit 1
fi

# Заменяем строку в файле /etc/asterisk/extensions.conf
config_file="/etc/asterisk/extensions.conf"
new_mixmon_dir="/CallRecords/Aster${AsterNumber}/"

if [ -f "$config_file" ]; then
    sudo sed -i "s|MIXMON_DIR *= *.*|MIXMON_DIR = ${new_mixmon_dir}|" "$config_file"
    echo "Строка MIXMON_DIR в файле $config_file обновлена на: MIXMON_DIR = ${new_mixmon_dir}"
else
    echo "Файл $config_file не найден."
    exit 1
fi

# Создаем новую папку
if [ ! -d "$new_mixmon_dir" ]; then
    sudo mkdir -p "$new_mixmon_dir"
    echo "Папка $new_mixmon_dir была успешно создана."
else
    echo "Папка $new_mixmon_dir уже существует."
fi

# Заменяем строку с доменом CRM в файле /etc/asterisk/extensions.conf
new_crm_url="https://${crm_domain}/v6_0/api/save-audio-request-call"
sudo sed -i "s|same => n,System(curl -X POST \${CURL_DATA} .* > /tmp/curl_response.txt 2>/tmp/curl_error.txt)|same => n,System(curl -X POST \${CURL_DATA} ${new_crm_url} > /tmp/curl_response.txt 2>/tmp/curl_error.txt)|" "$config_file"

echo "Строка с доменом CRM в файле $config_file обновлена на: same => n,System(curl -X POST \${CURL_DATA} ${new_crm_url} > /tmp/curl_response.txt 2>/tmp/curl_error.txt)"

# Формируем имя секции на основе введенного номера
section_name="Aster${AsterNumber}"

# Генерируем пароль длиной 20 символов
password=$(openssl rand -base64 20 | tr -d '/+=' | cut -c1-20)

# Новый содержимое файла manager.conf
new_manager_conf=";
; Asterisk Call Management support
;

; By default asterisk will listen on localhost only.
[general]
enabled = yes
port = 5038
bindaddr = 0.0.0.0

[${section_name}]
secret=${password}
permit=0.0.0.0/255.255.255.0
permit=0.0.0.0/255.255.255.0
read=system,call,log,verbose,command,agent,user,config,command,dtmf,reporting,cdr,dialplan,originate,message
write=system,call,log,verbose,command,agent,user,config,command,dtmf,reporting,cdr,dialplan,originate,message
writetimeout=5000


;No access is allowed by default.
; To set a password, create a file in /etc/asterisk/manager.d
; use creative permission games to allow other services to create their own
; files
"

# Путь к файлу конфигурации
config_file="/etc/asterisk/manager.conf"

# Замена содержимого файла /etc/asterisk/manager.conf
echo "$new_manager_conf" | sudo tee "$config_file" > /dev/null

# Вывод пароля зеленым цветом
tput setaf 2  # Устанавливаем зеленый цвет
echo "Сгенерированный пароль в /etc/asterisk/manager.conf: $password"
tput sgr0  # Сброс цвета

echo "Файл /etc/asterisk/manager.conf был успешно обновлен."

# Новый конфиг для файла rtp.conf
stunaddr_value="stun.${crm_domain}"

# Путь к файлу конфигурации rtp.conf
rtp_file="/etc/asterisk/rtp.conf"

# Обновляем строки в файле rtp.conf
if [ -f "$rtp_file" ]; then
    sudo sed -i 's|; icesupport=false|icesupport=true|' "$rtp_file"
    sudo sed -i 's|; stunaddr=.*|stunaddr='"$stunaddr_value"'|' "$rtp_file"
    echo "Файл $rtp_file был успешно обновлен."
else
    echo "Файл $rtp_file не найден."
    exit 1
fi

sudo systemctl restart asterisk

sudo asterisk -rx 'core reload'

sudo asterisk -rx 'http show status'