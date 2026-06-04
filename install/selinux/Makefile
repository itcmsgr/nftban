# NFTBan SELinux Policy Makefile (R39 v1.19.12)
# SPDX-License-Identifier: MPL-2.0
#
# Usage: make && make install
# Requirements: selinux-policy-devel, checkpolicy

POLICY_NAME = nftban
POLICY_VERSION = 1.1.0

all: $(POLICY_NAME).pp

$(POLICY_NAME).mod: $(POLICY_NAME).te
	@echo "Compiling SELinux module..."
	checkmodule -M -m -o $@ $<

$(POLICY_NAME).pp: $(POLICY_NAME).mod $(POLICY_NAME).fc
	@echo "Packaging SELinux policy..."
	semodule_package -o $@ -m $(POLICY_NAME).mod -f $(POLICY_NAME).fc

install: $(POLICY_NAME).pp
	@echo "Installing SELinux policy..."
	semodule -i $(POLICY_NAME).pp
	@echo "Applying file contexts..."
	restorecon -R /usr/sbin/nftban /usr/lib/nftban /etc/nftban /var/lib/nftban /var/log/nftban /run/nftban 2>/dev/null || true
	@echo "SELinux policy installed successfully"

uninstall:
	@echo "Removing SELinux policy..."
	semodule -r $(POLICY_NAME) 2>/dev/null || true
	@echo "SELinux policy removed"

status:
	@semodule -l | grep $(POLICY_NAME) || echo "Policy not installed"

clean:
	rm -f $(POLICY_NAME).mod $(POLICY_NAME).pp

.PHONY: all install uninstall status clean
