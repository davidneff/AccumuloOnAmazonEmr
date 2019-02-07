# Accumulo on Amazon EMR

## Intro
Amazon EMR allows you to use a [bootstrap action](https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-plan-bootstrap.html) to install additional software or customize the configuration of cluster instances. The bootstrap-accumulo script is an EMR bootstrap action that installs Apache Accumulo on an EMR cluster.

## Important Note
This is NOT production ready code. This is just meant for learning and expermentation purposes. Credit for these scripts belongs to https://github.com/locationtech/geowave and http://s3.amazonaws.com/geowave/0.9.4.1/docs/quickstart.html.  

## Prerequisites
The bootstrap-accumulo and accumulo-install-lib scripts must both be deployed to an S3 bucket that EMR can access. 

## Getting Started
Run the following command from the AWS CLI to create an EMR cluster that uses the bootstrap-accumulo bootstrap action to install Accumulo. To learn more about the create-cluster command see the [documentation](https://docs.aws.amazon.com/cli/latest/reference/emr/create-cluster.html).

```bash
# replace these with real values
EMR_VERSION="emr-5.20.0"
CLUSTER_NAME="TestCluster"
LOG_URI="s3://YOUR_S3_BUCKET_URL_HERE"
EC2_KEYPAIR_NAME="YOUR_EC2_KP_NAME_HERE"
SUBNET_ID="YOUR_SUBNET_ID_HERE"
EMR_MANAGED_MASTER_SG_ID="YOUR_EMR_MANAGED_MASTER_SG_ID"
EMR_MANAGED_SLAVE_SG_ID="YOUR_EMR_MANAGED_SLAVE_SG_ID"
ADDITIONAL_MASTER_SG_ID="YOUR_ADDITIONAL_MASTER_SG_ID"
TAGS="Application=TestApp Environment=Dev"
BOOTSTRAP_ACTION_PATH="s3://YOUR_S3_BUCKET_URL_HERE/bootstrap-accumulo.sh"

# create-cluster command call
aws emr create-cluster \
--release-label ${EMR_VERSION} \
--instance-groups InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m4.xlarge InstanceGroupType=CORE,InstanceCount=2,InstanceType=m4.xlarge \
--no-auto-terminate \
--use-default-roles \
--name ${CLUSTER_NAME} \
--log-uri ${LOG_URI} \
--ec2-attributes "KeyName=${EC2_KEYPAIR_NAME},SubnetId=${SUBNET_ID},EmrManagedMasterSecurityGroup=${EMR_MANAGED_MASTER_SG_ID},EmrManagedSlaveSecurityGroup=${EMR_MANAGED_SLAVE_SG_ID},AdditionalMasterSecurityGroups=${ADDITIONAL_MASTER_SG_ID}" \
--termination-protected \
--visible-to-all-users \
--enable-debugging \
--tags ${TAGS} \
--applications Name=Hadoop Name=Ganglia Name=Hive Name=Hue Name=Zeppelin Name=Zookeeper \
--bootstrap-actions Path=${BOOTSTRAP_ACTION_PATH},Name=Bootstrap_Accumulo 
```

## Script Debugging Info
The bootstrap action will create a file called /tmp/accumulo-install.log on each of the EC2 instances in the cluster that contains the details of the installation. You can verify there are no errors by SSHing to an instance and reviewing that log. 

Monitor installation log:
```bash
tail -n 500 -f /tmp/accumulo-install.log
```

Is Accumulo running?:
```bash
ps -aux | grep accumulo
```

## Known Issues
There is a known issue with the bootstrap-accumulo bootstrap action. Sometimes when running accumulo init on the master the script will fail because of a timing or perhaps a classpath issue. To work around this issue, if you notice in the log that init has failed, SSH into the master node and manually run accumulo init and then start Accumulo. 

Init Accumulo on the master node:
```bash
/opt/accumulo/bin/accumulo init --clear-instance-name --instance-name accumulo --password secret
```

Start Accumulo:
```bash
/opt/accumulo/bin/start-here.sh
```

## Connecting to the Accumulo Master Node
To connect to the Accumulo master and be able to view the Accumulo console web site you will need to SSH into the master with port forwarding. Run the following command replacing the variables with your own values:
```bash
ssh -i ${YOUR_PEM_FILE} -L 9995:${MASTER_LOCAL_IP}:9995 hadoop@${MASTER_PUBLIC_DNS}
```
For example:
```bash
ssh -i MyKP.pem -L 9995:10.0.0.94:9995 hadoop@ec2-18-123-45-678.compute-1.amazonaws.com
```

Once the ssh connection is established you can view the Accumulo console in your local workstations web browser by visiting http://localhost:9995/. 
