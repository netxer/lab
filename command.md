Often used commands:

ssh ubuntu@192.168.4.5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null


Cloud init commands:
sudo cloud-init status --long

Ansible commands:
ansible-playbook -i ansible_inventory.ini test-connectivity.yml