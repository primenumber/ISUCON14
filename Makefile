# 去年のやつのコピペ
all: app

SERVER_ID := s1
ADDR := 54.199.104.110

#SERVER_ID := s2
#ADDR := 54.64.80.21

#SERVER_ID := s3
#ADDR := 57.182.97.234

app:
	cd webapp/go; GOOS=linux GOARCH=amd64 go build -o isuride

deploy-app: app nginx-log-rotate mysql-log-rotate
	ssh isucon@$(ADDR) rm /home/isucon/webapp/go/isuride
	scp -r webapp/go isucon@$(ADDR):/home/isucon/webapp/
	ssh isucon@$(ADDR) sudo systemctl restart isuride-go.service

upload-sql:
	scp -r webapp/sql isucon@$(ADDR):/home/isucon/webapp/

deploy-mysql-only: mysql-log-rotate
	scp -r $(SERVER_ID)/etc/mysql isucon@$(ADDR):/tmp
	ssh isucon@$(ADDR) 'sudo cp -rT /tmp/mysql /etc/mysql ; sudo systemctl restart mysql'

mysql-log-rotate:
	ssh isucon@$(ADDR) "sudo rm /var/log/mysql/mysql-slow.log ; sudo systemctl restart mysql"

get-mysql-log:
	ssh isucon@$(ADDR) 'sudo chmod 644 /var/log/mysql/mysql-slow.log'
	scp isucon@$(ADDR):/var/log/mysql/mysql-slow.log /tmp

pt-query-digest:
	pt-query-digest /tmp/mysql-slow.log | tee /tmp/digest.txt.`date +%Y%m%d-%H%M%S`

deploy-nginx-only: nginx-log-rotate
	scp -r $(SERVER_ID)/etc/nginx isucon@$(ADDR):/tmp
	ssh isucon@$(ADDR) 'sudo cp -rT /tmp/nginx /etc/nginx ; sudo systemctl restart nginx'

nginx-log-rotate:
	ssh isucon@$(ADDR) "sudo mv /var/log/nginx/access.log /var/log/nginx/access.log.`date +%Y%m%d-%H%M%S` ; sudo systemctl restart nginx"

get-nginx-log:
	scp isucon@$(ADDR):/var/log/nginx/access.log /tmp

execute-alp:
	cat /tmp/access.log| alp ltsv --config=tool-config/alp/config.yml



# 新しく作ってみたやつ 

#include env.sh
# 変数定義 ------------------------

# SERVER_ID: env.sh内で定義

# 問題によって変わる変数
USER:=isucon
BIN_NAME:=isuride-go
BUILD_DIR:=/home/isucon/private_isu/webapp/golang
SERVICE_NAME:=isuride-go.service

DB_PATH:=/etc/mysql
NGINX_PATH:=/etc/nginx
SYSTEMD_PATH:=/etc/systemd/system

NGINX_LOG:=/var/log/nginx/access.log
DB_SLOW_LOG:=/var/log/mysql/mysql-slow.log

# メインで使うコマンド ------------------------

# サーバーの環境構築　ツールのインストール、gitまわりのセットアップ
.PHONY: setup
setup: install-tools git-setup enable-monitoring

# 設定ファイルなどを取得してgit管理下に配置する
.PHONY: get-conf
get-conf: check-server-id get-db-conf get-nginx-conf get-service-file get-envsh

# リポジトリ内の設定ファイルをそれぞれ配置する
.PHONY: deploy-conf
deploy-conf: check-server-id deploy-db-conf deploy-nginx-conf deploy-service-file deploy-envsh

# ベンチマークを走らせる直前に実行する
.PHONY: bench
bench: check-server-id mv-logs build deploy-conf restart

# slow queryを確認する
.PHONY: slow-query
slow-query:
	ssh isucon@$(ADDR) 'sudo pt-query-digest $(DB_SLOW_LOG)'

# alpでアクセスログを確認する
.PHONY: alp
alp:
	ssh isucon@$(ADDR) 'sudo alp ltsv --file=$(NGINX_LOG) --config=/home/isucon/tool-config/alp/config.yml'

# pprofで記録する
.PHONY: pprof-record
pprof-record:
	ssh isucon@$(ADDR) 'go tool pprof http://localhost:6060/debug/pprof/profile'

# pprofで確認する
.PHONY: pprof-check
pprof-check:
	ssh isucon@$(ADDR) '$(eval latest := $(shell ls -rt pprof/ | tail -n 1))'
	ssh isucon@$(ADDR) 'go tool pprof -http=localhost:8090 pprof/$(latest)'

# DBに接続する
.PHONY: access-db
access-db:
	ssh isucon@$(ADDR) 'mysql -h $(MYSQL_HOST) -P $(MYSQL_PORT) -u $(MYSQL_USER) -p$(MYSQL_PASS) $(MYSQL_DBNAME)0'

# モニタリングを停止する
.PHONY: disable-monitoring
disable-monitoring:
	ssh isucon@$(ADDR) 'sudo systemctl disable netdata'
	ssh isucon@$(ADDR) 'sudo systemctl stop netdata'

# 再起動する
.PHONY: reboot
reboot:
	ssh isucon@$(ADDR) 'sudo reboot'

# 主要コマンドの構成要素 ------------------------

.PHONY: install-tools
install-tools:
	ssh isucon@$(ADDR) 'sudo apt update'
	ssh isucon@$(ADDR) 'sudo apt upgrade'
	ssh isucon@$(ADDR) 'sudo apt install -y percona-toolkit dstat git unzip snapd graphviz tree'

	# alpのインストール
	ssh isucon@$(ADDR) 'wget https://github.com/tkuchiki/alp/releases/download/v1.0.9/alp_linux_amd64.zip'
	ssh isucon@$(ADDR) 'unzip alp_linux_amd64.zip'
	ssh isucon@$(ADDR) 'sudo install alp /usr/local/bin/alp'
	ssh isucon@$(ADDR) 'rm alp_linux_amd64.zip alp'

	# slpのインストール
	ssh isucon@$(ADDR) 'wget https://github.com/tkuchiki/slp/releases/download/v0.2.1/slp_linux_amd64.tar.gz'
	ssh isucon@$(ADDR) 'tar -xvf slp_linux_amd64.tar.gz'
	ssh isucon@$(ADDR) 'sudo mv slp /usr/local/bin/slp'
	ssh isucon@$(ADDR) 'rm slp_linux_amd64.tar.gz'

	# pproteinのインストール
	ssh isucon@$(ADDR) 'wget https://github.com/kaz/pprotein/releases/download/v1.2.4/pprotein_1.2.4_linux_amd64.tar.gz'
	ssh isucon@$(ADDR) 'tar -xvf pprotein_1.2.4_linux_amd64.tar.gz'

	# netdataのインストール
	ssh isucon@$(ADDR) 'wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh && sh /tmp/netdata-kickstart.sh'

.PHONY: git-setup
git-setup:
	# git用の設定は適宜変更して良い
	ssh isucon@$(ADDR) 'git config --global user.email "yu3mars@users.noreply.github.com"'
	ssh isucon@$(ADDR) 'git config --global user.name "yu3mars"'

	# deploykeyの作成
	ssh isucon@$(ADDR) 'ssh-keygen -t ed25519'

.PHONY: check-server-id
check-server-id:
ifdef SERVER_ID
	ssh isucon@$(ADDR) 'echo "SERVER_ID=$(SERVER_ID)"'
else
	ssh isucon@$(ADDR) 'echo "SERVER_ID is unset"'
	ssh isucon@$(ADDR) 'exit 1'
endif

.PHONY: set-as-s1
set-as-s1:
	ssh isucon@$(ADDR) 'echo "SERVER_ID=s1" >> env.sh'

.PHONY: set-as-s2
set-as-s2:
	ssh isucon@$(ADDR) 'echo "SERVER_ID=s2" >> env.sh'

.PHONY: set-as-s3
set-as-s3:
	ssh isucon@$(ADDR) 'echo "SERVER_ID=s3" >> env.sh'

.PHONY: get-db-conf
get-db-conf:
	ssh isucon@$(ADDR) 'mkdir -p ~/$(SERVER_ID)/etc/mysql'
	ssh isucon@$(ADDR) 'sudo cp -R $(DB_PATH)/* ~/$(SERVER_ID)/etc/mysql'
	ssh isucon@$(ADDR) 'sudo chown $(USER) -R ~/$(SERVER_ID)/etc/mysql'

.PHONY: get-nginx-conf
get-nginx-conf:
	ssh isucon@$(ADDR) 'mkdir -p ~/$(SERVER_ID)/etc/nginx'
	ssh isucon@$(ADDR) 'sudo cp -R $(NGINX_PATH)/* ~/$(SERVER_ID)/etc/nginx'
	ssh isucon@$(ADDR) 'sudo chown $(USER) -R ~/$(SERVER_ID)/etc/nginx'

.PHONY: get-service-file
get-service-file:
	ssh isucon@$(ADDR) 'mkdir -p ~/$(SERVER_ID)/etc/systemd/system'
	ssh isucon@$(ADDR) 'sudo cp $(SYSTEMD_PATH)/$(SERVICE_NAME) ~/$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME)'
	ssh isucon@$(ADDR) 'sudo chown $(USER) ~/$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME)'

.PHONY: get-envsh
get-envsh:
	ssh isucon@$(ADDR) 'mkdir -p ~/$(SERVER_ID)/home/isucon'
	ssh isucon@$(ADDR) 'cp ~/env.sh ~/$(SERVER_ID)/home/isucon/env.sh'

.PHONY: deploy-db-conf
deploy-db-conf:
	ssh isucon@$(ADDR) 'sudo mkdir -p $(DB_PATH)'
	ssh isucon@$(ADDR) 'sudo cp -R ~/$(SERVER_ID)/etc/mysql/* $(DB_PATH)'

.PHONY: deploy-nginx-conf
deploy-nginx-conf:
	ssh isucon@$(ADDR) 'sudo mkdir -p $(NGINX_PATH)'
	ssh isucon@$(ADDR) 'sudo cp -R ~/$(SERVER_ID)/etc/nginx/* $(NGINX_PATH)'

.PHONY: deploy-service-file
deploy-service-file:
	ssh isucon@$(ADDR) 'sudo mkdir -p $(SYSTEMD_PATH)'
	ssh isucon@$(ADDR) 'sudo cp ~/$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME) $(SYSTEMD_PATH)/$(SERVICE_NAME)'

.PHONY: deploy-envsh
deploy-envsh:
	ssh isucon@$(ADDR) 'cp ~/$(SERVER_ID)/home/isucon/env.sh ~/env.sh'

.PHONY: build
build:
	ssh isucon@$(ADDR) 'cd $(BUILD_DIR); go build -o $(BIN_NAME)'

.PHONY: restart
restart:
	ssh isucon@$(ADDR) 'sudo systemctl daemon-reload'
	ssh isucon@$(ADDR) 'sudo systemctl restart $(SERVICE_NAME)'
	ssh isucon@$(ADDR) 'sudo systemctl restart mysql'
	ssh isucon@$(ADDR) 'sudo systemctl restart nginx'

.PHONY: mv-logs
mv-logs:
	ssh isucon@$(ADDR) '$(eval when := $(shell date "+%s"))'
	ssh isucon@$(ADDR) 'mkdir -p ~/logs/$(when)'
	ssh isucon@$(ADDR) 'sudo test -f $(NGINX_LOG) && sudo mv -f $(NGINX_LOG) ~/logs/nginx/$(when)/ || echo ""'
	ssh isucon@$(ADDR) 'sudo test -f $(DB_SLOW_LOG) && sudo mv -f $(DB_SLOW_LOG) ~/logs/mysql/$(when)/ || echo ""'

.PHONY: watch-service-log
watch-service-log:
	ssh isucon@$(ADDR) 'sudo journalctl -u $(SERVICE_NAME) -n10 -f'

.PHONY: enable-monitoring
enable-monitoring:
	ssh isucon@$(ADDR) 'sudo systemctl enable netdata'