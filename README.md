Explanation for CKAlab


All VMs are created from the same base box (ubuntu/focal64).
User kubeadmin (password: kubepass123) is created and can SSH in.
Each VM gets a unique static IP (192.168.70.x) and a forwarded SSH port (22xx).
Only master1 runs the Kubernetes setup script automatically.
Other nodes (master2, worker1-worker4) can later join the cluster manually with:
sudo /root/join-master.sh
sudo /root/join-worker.sh
