MACOS_INV   := -i inventory/macos.yml -i inventory/orchard_inv.py
MACMINI_INV := -i inventory/macmini.yml
VAULT       ?= $(if $(ANSIBLE_VAULT_PASSWORD_FILE),,--ask-vault-pass)

.PHONY: macos-site macos-bootstrap macos-inventory macmini-site macmini-bootstrap macmini-prereq macmini-inventory macmini-ping

macos-site:
	ansible-playbook $(VAULT) $(MACOS_INV) playbooks/site.yml

macos-bootstrap:
	ansible-playbook $(VAULT) $(MACOS_INV) playbooks/bootstrap.yml

macos-inventory:
	ansible-inventory $(VAULT) $(MACOS_INV) --list --yaml

macmini-site:
	ansible-playbook $(VAULT) $(MACMINI_INV) playbooks/site.yml

macmini-bootstrap:
	ansible-playbook $(VAULT) $(MACMINI_INV) playbooks/bootstrap.yml

macmini-prereq:
	ansible-playbook $(VAULT) $(MACMINI_INV) playbooks/prerequisite.yml

macmini-inventory:
	ansible-inventory $(VAULT) $(MACMINI_INV) --list --yaml

macmini-ping:
	ansible $(VAULT) $(MACMINI_INV) k8s -m ping
