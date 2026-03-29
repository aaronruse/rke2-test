# A long list of helpful hints we should continue to add to for dealing with this deployment 

Make sure your ssh client is clean:
```
eval $(ssh-agent -s)
ssh-add -l
ssh-add -D
ssh-add ~/.ssh/rke2_id_ed25519
ssh-add -l
ssh -i ~/.ssh/rke2_id_ed25519 ubuntu@$(terraform output -raw bastion_public_ip)
```


```bash
aws ec2 describe-key-pairs \
  --key-names rke2-prod-keypair \
  --include-public-key \
  --region us-west-2 \
  --query 'KeyPairs[0].{Fingerprint:KeyFingerprint,PublicKey:PublicKey}' \
  --output json
```

```bash
ssh-keygen -l -f <(aws ec2 describe-key-pairs \
  --key-names rke2-prod-keypair \
  --include-public-key \
  --region us-west-2 \
  --query 'KeyPairs[0].PublicKey' \
  --output text)
```

# Your current public IP
curl -s https://api.ipify.org

# What the security group allows on port 22
```
aws ec2 describe-security-groups \
  --region us-west-2 \
  --filters "Name=tag:Name,Values=*bastion*" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`]' \
  --output json
```

If all of those fail, we can check the AMI metadata directly to find the correct username:
```bash
aws ec2 describe-images \
  --image-ids ami-0d76b909de1a0595d \
  --region us-west-2 \
  --query 'Images[0].Description' \
  --output text
```
And also check if there's any hint in the AMI's platform details:
```bash
aws ec2 describe-images \
  --image-ids ami-0d76b909de1a0595d \
  --region us-west-2 \
  --query 'Images[0].{Name:Name,Description:Description,Platform:Platform,PlatformDetails:PlatformDetails}' \
  --output json
```

Let's check the instance system log to see what happened on boot:
```bash
aws ec2 get-console-output \
  --instance-id $(aws ec2 describe-instances \
    --region us-west-2 \
    --filters "Name=tag:Role,Values=bastion" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text) \
  --region us-west-2 \
  --output text | tail -50
```

This will show the boot log and any cloud-init errors. Also check the instance state is actually running:
```bash
aws ec2 describe-instances \
  --region us-west-2 \
  --filters "Name=tag:Role,Values=bastion" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,InstanceId:InstanceId}' \
  --output json
```


Confirm the deployment from the CLI as it runs

connect to workspace
```
ssh rhel-admin@10.0.0.68
```

check key on workspace
```
ssh-add -l
```

connect to bastion
```
ssh -A -i ~/.ssh/rke2_id_ed25519 ubuntu@$(terraform output -raw bastion_public_ip)
```

check key on bastion
```
ssh-add -l
```

```
ubuntu@ip-10-0-0-99:~$ aws ec2 describe-instances \
  --region us-west-2 \
  --filters "Name=tag:Name,Values=rke2-prod*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`]|[0].Value,ID:InstanceId,IP:PrivateIpAddress,State:State.Name}' \
  --output table
-----------------------------------------------------------------------------------------------
|                                      DescribeInstances                                      |
+---------------------+-------------+---------------------------------------------+-----------+
|         ID          |     IP      |                    Name                     |   State   |
+---------------------+-------------+---------------------------------------------+-----------+
|  i-053e095f2d4fc49fc|  10.0.1.137 |  rke2-prod-o5i-server-rke2-nodepool         |  running  |
|  i-080bc1001848fb4aa|  10.0.2.38  |  rke2-prod-o5i-workers-agent-rke2-nodepool  |  running  |
|  i-01810c256c4a33676|  10.0.2.40  |  rke2-prod-o5i-workers-agent-rke2-nodepool  |  running  |
|  i-0547a8680f2850e40|  10.0.2.170 |  rke2-prod-o5i-workers-agent-rke2-nodepool  |  running  |
|  i-03ef417a8122615de|  10.0.2.250 |  rke2-prod-o5i-workers-agent-rke2-nodepool  |  running  |
|  i-08352c43eee66288b|  10.0.0.99  |  rke2-prod-bastion                          |  running  |
+---------------------+-------------+---------------------------------------------+-----------+
```

```
ubuntu@ip-10-0-0-99:~$ aws autoscaling describe-auto-scaling-groups \
  --region us-west-2 \
  --query 'AutoScalingGroups[?contains(AutoScalingGroupName, `rke2-prod`)].{Name:AutoScalingGroupName,Desired:DesiredCapacity,InService:Instances[?LifecycleState==`InService`]|length(@),Healthy:Instances[?HealthStatus==`Healthy`]|length(@)}' \
  --output table
----------------------------------------------------------------------------------
|                            DescribeAutoScalingGroups                           |
+---------+----------+------------+----------------------------------------------+
| Desired | Healthy  | InService  |                    Name                      |
+---------+----------+------------+----------------------------------------------+
|  0      |  0       |  0         |  rke2-prod-jkx-server-rke2-nodepool          |
|  1      |  1       |  1         |  rke2-prod-o5i-server-rke2-nodepool          |
|  4      |  4       |  4         |  rke2-prod-o5i-workers-agent-rke2-nodepool   |
|  0      |  0       |  0         |  rke2-prod-s02-server-rke2-nodepool          |
+---------+----------+------------+----------------------------------------------+
```

connect to cp
```
ssh ubuntu@cp_ip1
```

bash# Is rke2-server running?
sudo systemctl status rke2-server

# Last 50 lines of logs
sudo journalctl -u rke2-server -n 50 --no-pager

# Are nodes registered?
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get nodes -o wide

# Are system pods running?
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get pods -A