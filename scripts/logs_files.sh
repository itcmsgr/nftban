#Checking for common log files :
#!/bin/bash
echo 'Checking for common log files:'
echo 'SSH (sshd):'
if [ -f /var/log/secure ]; then echo '  - Found: /var/log/secure'; fi
if [ -f /var/log/auth.log ]; then echo '  - Found: /var/log/auth.log'; fi
echo 'Dovecot:'
if [ -f /var/log/maillog ]; then echo '  - Found: /var/log/maillog'; fi
if [ -f /var/log/mail.log ]; then echo '  - Found: /var/log/mail.log'; fi
echo 'Postfix:'
if [ -f /var/log/maillog ]; then echo '  - Found: /var/log/maillog'; fi
if [ -f /var/log/mail.log ]; then echo '  - Found: /var/log/mail.log'; fi
echo 'Sendmail:'
if [ -f /var/log/maillog ]; then echo '  - Found: /var/log/maillog'; fi
if [ -f /var/log/mail.log ]; then echo '  - Found: /var/log/mail.log'; fi
echo 'Exim:'
if [ -f /var/log/exim/main.log ]; then echo '  - Found: /var/log/exim/main.log'; fi
if [ -f /var/log/exim4/mainlog ]; then echo '  - Found: /var/log/exim4/mainlog'; fi
echo 'Apache (httpd):'
if [ -f /var/log/httpd/access_log ]; then echo '  - Found: /var/log/httpd/access_log'; fi
if [ -f /var/log/apache2/access.log ]; then echo '  - Found: /var/log/apache2/access.log'; fi
echo 'Apache Error:'
if [ -f /var/log/httpd/error_log ]; then echo '  - Found: /var/log/httpd/error_log'; fi
if [ -f /var/log/apache2/error.log ]; then echo '  - Found: /var/log/apache2/error.log'; fi
echo 'Nginx Access:'
if [ -f /var/log/nginx/access.log ]; then echo '  - Found: /var/log/nginx/access.log'; fi
echo 'Nginx Error:'
if [ -f /var/log/nginx/error.log ]; then echo '  - Found: /var/log/nginx/error.log'; fi
echo 'Cron:'
if [ -f /var/log/cron ]; then echo '  - Found: /var/log/cron'; fi
if [ -f /var/log/syslog ]; then echo '  - Found: /var/log/syslog'; fi
if [ -f /var/log/cron.log ]; then echo '  - Found: /var/log/cron.log'; fi
echo 'Kernel:'
if [ -f /var/log/messages ]; then echo '  - Found: /var/log/messages'; fi
if [ -f /var/log/kernel.log ]; then echo '  - Found: /var/log/kernel.log'; fi
if [ -f /var/log/kern.log ]; then echo '  - Found: /var/log/kern.log'; fi
echo 'System Boot:'
if [ -f /var/log/boot.log ]; then echo '  - Found: /var/log/boot.log'; fi
echo 'Authentication:'
if [ -f /var/log/secure ]; then echo '  - Found: /var/log/secure'; fi
if [ -f /var/log/auth.log ]; then echo '  - Found: /var/log/auth.log'; fi
echo 'General Syslog:'
if [ -f /var/log/messages ]; then echo '  - Found: /var/log/messages'; fi
if [ -f /var/log/syslog ]; then echo '  - Found: /var/log/syslog'; fi
echo 'Auditd:'
if [ -f /var/log/audit/audit.log ]; then echo '  - Found: /var/log/audit/audit.log'; fi
echo 'UFW (Debian firewall):'
if [ -f /var/log/ufw.log ]; then echo '  - Found: /var/log/ufw.log'; fi
echo 'Sudo:'
if [ -f /var/log/secure ]; then echo '  - Found: /var/log/secure'; fi
if [ -f /var/log/auth.log ]; then echo '  - Found: /var/log/auth.log'; fi
echo 'Plesk:'
if [ -f /var/log/plesk/panel.log ]; then echo '  - Found: /var/log/plesk/panel.log'; fi
echo 'DirectAdmin:'
if [ -f /var/log/directadmin/error.log ]; then echo '  - Found: /var/log/directadmin/error.log'; fi
echo 'cPanel:'
if [ -f /usr/local/cpanel/logs/error_log ]; then echo '  - Found: /usr/local/cpanel/logs/error_log'; fi
echo 'MySQL:'
if [ -f /var/log/mysql/error.log ]; then echo '  - Found: /var/log/mysql/error.log'; fi
if [ -f /var/log/mysqld.log ]; then echo '  - Found: /var/log/mysqld.log'; fi
echo 'MariaDB:'
if [ -f /var/log/mysql/mariadb.log ]; then echo '  - Found: /var/log/mysql/mariadb.log'; fi
if [ -f /var/log/mariadb/mariadb.log ]; then echo '  - Found: /var/log/mariadb/mariadb.log'; fi
echo 'fail2ban:'
if [ -f /var/log/fail2ban.log ]; then echo '  - Found: /var/log/fail2ban.log'; fi
