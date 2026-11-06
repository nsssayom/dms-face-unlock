# System files need root; the plugin itself lives in your home folder.
#
#   sudo make install-system    helper and polkit policy
#   make link                   link this folder into the shell's plugins (for development)
#   make check                  lint, then test the helper (the tests use sudo)

PREFIX ?= /usr
HELPER_DIR = $(DESTDIR)$(PREFIX)/lib/dms-face-unlock
POLICY_DIR = $(DESTDIR)$(PREFIX)/share/polkit-1/actions
POLICY = io.github.nsssayom.dmsfaceunlock.policy
PLUGIN_DIR ?= $(HOME)/.config/DankMaterialShell/plugins/faceUnlock

.PHONY: install-system uninstall-system link unlink check

install-system:
	install -Dm755 system/faceunlock-helper $(HELPER_DIR)/faceunlock-helper
	install -Dm644 system/$(POLICY) $(POLICY_DIR)/$(POLICY)

uninstall-system:
	rm -f $(HELPER_DIR)/faceunlock-helper $(POLICY_DIR)/$(POLICY)
	-rmdir $(HELPER_DIR)

link:
	mkdir -p $(dir $(PLUGIN_DIR))
	ln -sfn $(CURDIR) $(PLUGIN_DIR)

unlink:
	rm -f $(PLUGIN_DIR)

check:
	shellcheck -e SC2162,SC2016 system/faceunlock-helper tests/test-helper.sh
	sudo tests/test-helper.sh
