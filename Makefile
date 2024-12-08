# 去年のやつのコピペ
all: app

ADDR := 54.199.104.110

app:
	cd webapp/go; GOOS=linux GOARCH=amd64 go build -o isuride

deploy-app: app nginx-log-rotate mysql-log-rotate
	ssh isucon@$(ADDR) rm /home/isucon/webapp/go/isuride
	scp -r webapp/go isucon@$(ADDR):/home/isucon/webapp/
	ssh isucon@$(ADDR) sudo systemctl restart isuride-go.service

upload-sql:
	scp -r webapp/sql isucon@$(ADDR):/home/isucon/webapp/

deploy-mysql-only: mysql-log-rotate
	scp -r etc/mysql isucon@$(ADDR):/tmp
	ssh isucon@$(ADDR) 'sudo cp -rT /tmp/mysql /etc/mysql ; sudo systemctl restart mysql'

mysql-log-rotate:
	ssh isucon@$(ADDR) "sudo rm /var/log/mysql/mysql-slow.log ; sudo systemctl restart mysql"

get-mysql-log:
	ssh isucon@$(ADDR) 'sudo chmod 644 /var/log/mysql/mysql-slow.log'
	scp isucon@$(ADDR):/var/log/mysql/mysql-slow.log /tmp

pt-query-digest:
	pt-query-digest /tmp/mysql-slow.log | tee /tmp/digest.txt.`date +%Y%m%d-%H%M%S`

deploy-nginx-only: nginx-log-rotate
	scp -r etc/nginx isucon@$(ADDR):/tmp
	ssh isucon@$(ADDR) 'sudo cp -rT /tmp/nginx /etc/nginx ; sudo systemctl restart nginx'

nginx-log-rotate:
	ssh isucon@$(ADDR) "sudo mv /var/log/nginx/access.log /var/log/nginx/access.log.`date +%Y%m%d-%H%M%S` ; sudo systemctl restart nginx"

get-nginx-log:
	scp isucon@$(ADDR):/var/log/nginx/access.log /tmp

alp:
	cat /tmp/access.log| alp json -m "/api/user/[0-9a-zA-Z]*/livestream,/api/user/[0-9a-zA-Z]*/statistics,/api/livestream/[0-9a-zA-Z]*/livecomment,/api/livestream/[0-9a-zA-Z]*/reaction,/api/livestream/[0-9a-zA-Z]*/moderate,/api/livestream/[0-9a-zA-Z]*/statistics,/api/livestream/[0-9a-zA-Z]*/report,/api/livestream/[0-9a-zA-Z]*/enter,/api/livestream/[0-9a-zA-Z]*/ngwords,/api/livestream/[0-9a-zA-Z]*/exit,/api/user/[0-9a-zA-Z]*/icon,/api/user/[0-9a-zA-Z]*/theme,/api/livestream/[0-9a-zA-Z]*/livecomment/[0-9a-zA-Z]*/report" --sort=sum -r



# 新しく作ってみたやつ サーバーにログインして使う前提

include env.sh
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
bench: check-server-id mv-logs build deploy-conf restart watch-service-log

# slow queryを確認する
.PHONY: slow-query
slow-query:
	sudo pt-query-digest $(DB_SLOW_LOG)

# alpでアクセスログを確認する
.PHONY: alp
alp:
	sudo alp ltsv --file=$(NGINX_LOG) --config=/home/isucon/tool-config/alp/config.yml

# pprofで記録する
.PHONY: pprof-record
pprof-record:
	go tool pprof http://localhost:6060/debug/pprof/profile

# pprofで確認する
.PHONY: pprof-check
pprof-check:
	$(eval latest := $(shell ls -rt pprof/ | tail -n 1))
	go tool pprof -http=localhost:8090 pprof/$(latest)

# DBに接続する
.PHONY: access-db
access-db:
	mysql -h $(MYSQL_HOST) -P $(MYSQL_PORT) -u $(MYSQL_USER) -p$(MYSQL_PASS) $(MYSQL_DBNAME)0

# モニタリングを停止する
.PHONY: disable-monitoring
disable-monitoring:
	sudo systemctl disable netdata
	sudo systemctl stop netdata

# 再起動する
.PHONY: reboot
reboot:
	sudo reboot

# 主要コマンドの構成要素 ------------------------

.PHONY: install-tools
install-tools:
	sudo apt update
	sudo apt upgrade
	sudo apt install -y percona-toolkit dstat git unzip snapd graphviz tree

	# alpのインストール
	wget https://github.com/tkuchiki/alp/releases/download/v1.0.9/alp_linux_amd64.zip
	unzip alp_linux_amd64.zip
	sudo install alp /usr/local/bin/alp
	rm alp_linux_amd64.zip alp

	# slpのインストール
	wget https://github.com/tkuchiki/slp/releases/download/v0.2.1/slp_linux_amd64.tar.gz
	tar -xvf slp_linux_amd64.tar.gz
	sudo mv slp /usr/local/bin/slp
	rm slp_linux_amd64.tar.gz

	# pproteinのインストール
	wget https://github.com/kaz/pprotein/releases/download/v1.2.4/pprotein_1.2.4_linux_amd64.tar.gz
	tar -xvf pprotein_1.2.4_linux_amd64.tar.gz

	# netdataのインストール
	wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh && sh /tmp/netdata-kickstart.sh

.PHONY: git-setup
git-setup:
	# git用の設定は適宜変更して良い
	git config --global user.email "yu3mars@users.noreply.github.com"
	git config --global user.name "yu3mars"

	# deploykeyの作成
	ssh-keygen -t ed25519

.PHONY: check-server-id
check-server-id:
ifdef SERVER_ID
	@echo "SERVER_ID=$(SERVER_ID)"
else
	@echo "SERVER_ID is unset"
	@exit 1
endif

.PHONY: set-as-s1
set-as-s1:
	echo "SERVER_ID=s1" >> env.sh

.PHONY: set-as-s2
set-as-s2:
	echo "SERVER_ID=s2" >> env.sh

.PHONY: set-as-s3
set-as-s3:
	echo "SERVER_ID=s3" >> env.sh

.PHONY: get-db-conf
get-db-conf:
	mkdir -p ~/$(SERVER_ID)/etc/mysql
	sudo cp -R $(DB_PATH)/* ~/$(SERVER_ID)/etc/mysql
	sudo chown $(USER) -R ~/$(SERVER_ID)/etc/mysql

.PHONY: get-nginx-conf
get-nginx-conf:
	mkdir -p ~/$(SERVER_ID)/etc/nginx
	sudo cp -R $(NGINX_PATH)/* ~/$(SERVER_ID)/etc/nginx
	sudo chown $(USER) -R ~/$(SERVER_ID)/etc/nginx

.PHONY: get-service-file
get-service-file:
	mkdir -p ~/$(SERVER_ID)/etc/systemd/system
	sudo cp $(SYSTEMD_PATH)/$(SERVICE_NAME) ~/$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME)
	sudo chown $(USER) ~/$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME)

.PHONY: get-envsh
get-envsh:
	mkdir -p ~/$(SERVER_ID)/home/isucon
	cp ~/env.sh ~/$(SERVER_ID)/home/isucon/env.sh

.PHONY: deploy-db-conf
deploy-db-conf:
	sudo mkdir -p $(DB_PATH)
	sudo cp -R ~/$(SERVER_ID)/etc/mysql/* $(DB_PATH)

.PHONY: deploy-nginx-conf
deploy-nginx-conf:
	sudo mkdir -p $(NGINX_PATH)
	sudo cp -R ~/$(SERVER_ID)/etc/nginx/* $(NGINX_PATH)

.PHONY: deploy-service-file
deploy-service-file:
	sudo mkdir -p $(SYSTEMD_PATH)
	sudo cp ~/$(SERVER_ID)/etc/systemd/system/$(SERVICE_NAME) $(SYSTEMD_PATH)/$(SERVICE_NAME)

.PHONY: deploy-envsh
deploy-envsh:
	cp ~/$(SERVER_ID)/home/isucon/env.sh ~/env.sh

.PHONY: build
build:
	cd $(BUILD_DIR); \
	go build -o $(BIN_NAME)

.PHONY: restart
restart:
	sudo systemctl daemon-reload
	sudo systemctl restart $(SERVICE_NAME)
	sudo systemctl restart mysql
	sudo systemctl restart nginx

.PHONY: mv-logs
mv-logs:
	$(eval when := $(shell date "+%s"))
	mkdir -p ~/logs/$(when)
	sudo test -f $(NGINX_LOG) && \
		sudo mv -f $(NGINX_LOG) ~/logs/nginx/$(when)/ || echo ""
	sudo test -f $(DB_SLOW_LOG) && \
		sudo mv -f $(DB_SLOW_LOG) ~/logs/mysql/$(when)/ || echo ""

.PHONY: watch-service-log
watch-service-log:
	sudo journalctl -u $(SERVICE_NAME) -n10 -f

.PHONY: enable-monitoring
enable-monitoring:
	sudo systemctl enable netdata
