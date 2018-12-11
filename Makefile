SHELL := /bin/bash

DEFAULTCONTENT_DB_VERSION := "0.1.25"
DEFAULTCONTENT_IMAGE_VERSION := "1-25"

SCALE_OPENRESTY ?=1
SCALE_APP ?=1

DOCKER_COMPOSE_FILE ?= docker-compose.yml

MYSQL_USER := $(shell grep MYSQL_USER db.env | cut -d'=' -f2)
MYSQL_PASS := $(shell grep MYSQL_PASSWORD db.env | cut -d'=' -f2)
ROOT_PASS := $(shell grep MYSQL_ROOT_PASSWORD db.env | cut -d'=' -f2)

WP_USER ?=${shell whoami}
WP_USER_EMAIL ?=${shell git config --get user.email}

PROJECT ?= $(shell basename "$(PWD)" | sed 's/[.-]//g')

.DEFAULT_GOAL := run

NGINX_HELPER_JSON := $(shell cat options/rt_wp_nginx_helper_options.json)
REWRITE := /%category%/%post_id%/%postname%/

DEFAULTCONTENT_BASE := "https://storage.googleapis.com/planet4-default-content"
DEFAULTCONTENT_DB := "$(DEFAULTCONTENT_BASE)/planet4-defaultcontent_wordpress-v$(DEFAULTCONTENT_DB_VERSION).sql.gz"
DEFAULTCONTENT_IMAGES := "$(DEFAULTCONTENT_BASE)/planet4-default-content-$(DEFAULTCONTENT_IMAGE_VERSION)-images.zip"

defaultcontent:
	@mkdir -p defaultcontent

defaultcontent/db.sql.gz: defaultcontent
	@echo "Downloading default content database"
	@curl $(DEFAULTCONTENT_DB) > $@

defaultcontent/images.zip: defaultcontent
	@echo "Downloading default content images"
	@curl $(DEFAULTCONTENT_IMAGES) > $@

.PHONY: getdefaultcontent
getdefaultcontent: defaultcontent/db.sql.gz defaultcontent/images.zip

.PHONY: cleandefaultcontent
cleandefaultcontent:
	@rm -rf defaultcontent

.PHONY: updatedefaultcontent
updatedefaultcontent: cleandefaultcontent getdefaultcontent

.PHONY: unzipimages
unzipimages:
	@unzip defaultcontent/images.zip -d persistence/app/public/wp-content/uploads

.PHONY : build
build : clean test getdefaultcontent run unzipimages config

.PHONY : test
test: test-sh test-yaml test-json

test-sh:
	find . -type f -name '*.sh' -not -path "./persistence/*" | xargs shellcheck

test-yaml:
	find . -type f -name '*.yml' -not -path "./persistence/*" | xargs yamllint
test-json:
	find . -type f -name '*.json' -not -path "./persistence/*" | xargs jq type

.PHONY : clean
clean: cleandefaultcontent
		./clean.sh

.PHONY : update
update:
		./update.sh

.PHONY : pull
pull:
		docker-compose -p $(PROJECT) -f $(DOCKER_COMPOSE_FILE) pull

.PHONY : run
run:
		SCALE_APP=$(SCALE_APP) \
		SCALE_OPENRESTY=$(SCALE_OPENRESTY) \
		PROJECT=$(PROJECT) \
		./go.sh
		@echo "Installing Wordpress, please wait..."
		@echo "This may take up to 10 minutes on the first run!"

		PROJECT=$(PROJECT) \
		./wait.sh

.PHONY : watch
watch:
		@echo "Running Planet 4 application script..."
		./watch.sh

.PHONY : stop
stop:
		./stop.sh

.PHONY : stateless
stateless: clean test start-stateless config

.PHONY: start-stateless
start-stateless:
		DOCKER_COMPOSE_FILE=docker-compose.stateless.yml \
		SCALE_APP=$(SCALE_APP) \
		SCALE_OPENRESTY=$(SCALE_OPENRESTY) \
		PROJECT=$(PROJECT) \
		./go.sh
		PROJECT=$(PROJECT) \
		./wait.sh

.PHONY: config
config:
		docker-compose -p $(PROJECT) exec -T php-fpm wp rewrite structure $(REWRITE)
		docker-compose -p $(PROJECT) exec -T php-fpm wp option set rt_wp_nginx_helper_options '$(NGINX_HELPER_JSON)' --format=json
		docker-compose -p $(PROJECT) exec php-fpm wp user update admin --user_pass=admin --role=administrator
		docker-compose -p $(PROJECT) exec php-fpm wp plugin deactivate wp-stateless

.PHONY : pass
pass:
		@make pmapass
		@make wppass

.PHONY : wppass
wppass:
		@printf "Wordpress credentials:\n"
		@printf "User:  admin\n"
		@printf "Pass:  "
		@docker-compose -p $(PROJECT) logs php-fpm | grep Admin | cut -d':' -f2 | xargs
		@printf "\n"

.PHONY : pmapass
pmapass:
		@printf "Database credentials:\n"
		@printf "User:  %s\n" $(MYSQL_USER)
		@printf "Pass:  %s\n----\n" $(MYSQL_PASS)
		@printf "User:  root\n"
		@printf "Pass:  %s\n----\n" $(ROOT_PASS)

.PHONY : wpadmin
wpadmin:
		docker-compose -p $(PROJECT) exec -T php-fpm wp user create ${WP_USER} ${WP_USER_EMAIL} --role=administrator

.PHONY: flush
flush:
	  docker-compose -p $(PROJECT) exec redis redis-cli flushdb


.PHONY: php
php:
		@docker-compose -p $(PROJECT) -f $(DOCKER_COMPOSE_FILE) run --rm --no-deps php-fpm bash

.PHONY: test-wp
test-wp:
		@docker-compose -p $(PROJECT) -f $(DOCKER_COMPOSE_FILE) run --rm --no-deps php-fpm vendor/bin/codecept run