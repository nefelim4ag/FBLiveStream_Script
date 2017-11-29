PREFIX ?= /

default:  help

install: ## Install fbstream
install:
	mkdir -p 				$(PREFIX)/etc/fbstream/
	install -Dm755	./fbstream.sh		$(PREFIX)/usr/bin/fbstream
	install -Dm644	./fbstream.service	$(PREFIX)/lib/systemd/system/fbstream.service
	install -Dm644	./default.conf.sample	$(PREFIX)/etc/fbstream/default.conf.sample

uninstall: ## Delete fbstream
uninstall:
	rm -v $(PREFIX)/usr/bin/fbstream
	rm -v $(PREFIX)/lib/systemd/system/fbstream.service
	rm -v $(PREFIX)/etc/fbstream/default.conf.sample
	rmdir -v $(PREFIX)/etc/fbstream/

help: ## Show help
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/\t/'
