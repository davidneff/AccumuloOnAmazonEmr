#!/usr/bin/env bash
#
# Credit for this script belongs to https://github.com/locationtech/geowave and http://s3.amazonaws.com/geowave/0.9.4.1/docs/quickstart.html 
# 
# Installing additional components on an EMR node depends on several config files
# controlled by the EMR framework which may affect the is_master and configure_zookeeper
# functions at some point in the future. I've grouped each unit of work into a function 
# with a descriptive name to help with understanding and maintainability
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

INTIAL_POLLING_INTERVAL=15 # This gets doubled for each attempt up to max_attempts

# Parses a configuration file put in place by EMR to determine the role of this node
is_master() {
  if [ $(jq '.isMaster' /mnt/var/lib/info/instance.json) = 'true' ]; then
	echo "this is the master"
    return 0
  else
	echo "this is not the master"
    return 1
  fi
}

# Avoid race conditions and actually poll for availability of component dependencies
# Credit: http://stackoverflow.com/questions/8350942/how-to-re-run-the-curl-command-automatically-when-the-error-occurs/8351489#8351489
with_backoff() {
  local max_attempts=${ATTEMPTS-5}
  local timeout=${INTIAL_POLLING_INTERVAL-1}
  local attempt=0
  local exitCode=0

  while (( $attempt < $max_attempts ))
  do
    set +e
    "$@"
    exitCode=$?
    set -e

    if [[ $exitCode == 0 ]]
    then
      break
    fi

    echo "Retrying $@ in $timeout.." 1>&2
    sleep $timeout
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout * 2 ))
  done

  if [[ $exitCode != 0 ]]
  then
    echo "Fail: $@ failed to complete after $max_attempts attempts" 1>&2
  fi

  return $exitCode
}

is_hdfs_available() {
	hadoop fs -ls /
	return $?
}

wait_until_hdfs_is_available() {
	with_backoff is_hdfs_available
	if [ $? != 0 ]; then
		echo "HDFS not available before timeout. Exiting ..."
		exit 1
	fi
}

#!/usr/bin/env bash
#
# Accumulo
# NOTE: The Accumulo instance secret and password are left at the default settings. 
# This could (should) be modified to use Secrets Manager to retrieve the password securly. 
USERPW=secret 
ACCUMULO_VERSION=1.9.2
ACCUMULO_TSERVER_OPTS=3GB
INSTALL_DIR=/opt
ACCUMULO_DOWNLOAD_BASE_URL=https://archive.apache.org/dist/accumulo
ACCUMULO_INSTANCE=accumulo
ACCUMULO_HOME="${INSTALL_DIR}/accumulo"
HADOOP_USER=hadoop
ZK_HOSTNAME=

# Using zookeeper packaged by Apache BigTop for ease of installation
configure_zookeeper() {
	echo "configure zookeeper - start"
	if is_master ; then
		#echo "configure zookeeper - installing zookeeper"
		#sudo yum -y install zookeeper-server # EMR 4.3.0 includes Apache Bigtop.repo config
		
		#echo "configure zookeeper - start zookeeper"
		#sudo initctl start zookeeper-server  # EMR uses Amazon Linux which uses Upstart
		
		# Zookeeper installed on this node, record internal ip from instance metadata
		#ZK_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
		ZK_HOSTNAME=$(hostname)
	else
		# Zookeeper intalled on master node, parse config file to find EMR master node
		#ZK_IP=$(xmllint --xpath "//property[name='yarn.resourcemanager.hostname']/value/text()"  /etc/hadoop/conf/yarn-site.xml)
		ZK_FQ_HOSTNAME=$(xmllint --xpath "//property[name='yarn.timeline-service.hostname']/value/text()"  /etc/hadoop/conf/yarn-site.xml)
		ZK_HOSTNAME=$(echo $ZK_FQ_HOSTNAME | sed -e 's/.ec2.internal//')
	fi
	echo "configure zookeeper - done"
}

install_accumulo() {
	echo "installing accumulo - start"
	echo "installing accumulo - wait_until_hdfs_is_available..."
	wait_until_hdfs_is_available

	echo "installing accumulo - hdfs ready, go time."
	ARCHIVE_FILE="accumulo-${ACCUMULO_VERSION}-bin.tar.gz"
	LOCAL_ARCHIVE="${INSTALL_DIR}/${ARCHIVE_FILE}"
	sudo sh -c "curl '${ACCUMULO_DOWNLOAD_BASE_URL}/${ACCUMULO_VERSION}/${ARCHIVE_FILE}' > $LOCAL_ARCHIVE"
	sudo sh -c "tar xzf $LOCAL_ARCHIVE -C $INSTALL_DIR"
	sudo rm -f $LOCAL_ARCHIVE
	sudo ln -s "${INSTALL_DIR}/accumulo-${ACCUMULO_VERSION}" "${INSTALL_DIR}/accumulo"

	echo "installing accumulo - change accumulo folder owner"
	sudo chown -R $HADOOP_USER:$HADOOP_USER "${INSTALL_DIR}/accumulo-${ACCUMULO_VERSION}"
	sudo chown -R $HADOOP_USER:$HADOOP_USER $INSTALL_DIR/accumulo

	echo "installing accumulo - set PATH"
	export PATH=$PATH:${INSTALL_DIR}/accumulo/bin
	sudo sh -c "echo 'export PATH=$PATH:${INSTALL_DIR}/accumulo/bin' > /etc/profile.d/accumulo.sh"

	echo "installing accumulo - done"
}

configure_accumulo() {
	echo "configuring accumulo - start"
	cp $INSTALL_DIR/accumulo/conf/examples/${ACCUMULO_TSERVER_OPTS}/native-standalone/* $INSTALL_DIR/accumulo/conf/
	
	sed -i "s/<value>localhost:2181<\/value>/<value>${ZK_HOSTNAME}:2181<\/value>/" $INSTALL_DIR/accumulo/conf/accumulo-site.xml
	sed -i '/HDP 2.0 requirements/d' $INSTALL_DIR/accumulo/conf/accumulo-site.xml
	#sed -i "s/\${LOG4J_JAR}/\${LOG4J_JAR}:\/usr\/lib\/hadoop\/lib\/*:\/usr\/lib\/hadoop\/client\/*/" $INSTALL_DIR/accumulo/bin/accumulo

	echo "configuring accumulo - set environment vars"
	ENV_FILE="export ACCUMULO_HOME=$INSTALL_DIR/accumulo; export HADOOP_HOME=/usr/lib/hadoop; export ACCUMULO_LOG_DIR=$INSTALL_DIR/accumulo/logs; export JAVA_HOME=/usr/lib/jvm/java; export ZOOKEEPER_HOME=/usr/lib/zookeeper; export HADOOP_PREFIX=/usr/lib/hadoop; export HADOOP_CONF_DIR=/etc/hadoop/conf; export ACCUMULO_CONF_DIR=$INSTALL_DIR/accumulo/conf;"
	echo $ENV_FILE > $INSTALL_DIR/accumulo/conf/accumulo-env.sh
	source $INSTALL_DIR/accumulo/conf/accumulo-env.sh

	echo "configuring accumulo - build_native_library"
	$INSTALL_DIR/accumulo/bin/build_native_library.sh

	echo "configuring accumulo - set accumulo/conf roles"
	if is_master ; then
		hostname > $INSTALL_DIR/accumulo/conf/monitor
		hostname > $INSTALL_DIR/accumulo/conf/gc
		hostname > $INSTALL_DIR/accumulo/conf/tracers
		hostname > $INSTALL_DIR/accumulo/conf/masters
		echo > $INSTALL_DIR/accumulo/conf/slaves

		echo "configuring accumulo - wating for is_zookeeper_initialized..."
		with_backoff is_zookeeper_initialized

		echo "configuring accumulo - what is in the classpath?"
		$INSTALL_DIR/accumulo/bin/accumulo classpath
		echo "configuring accumulo - classpath done"

		echo "configuring accumulo - run $INSTALL_DIR/accumulo/bin/accumulo init --clear-instance-name --instance-name $ACCUMULO_INSTANCE --password $USERPW"
		$INSTALL_DIR/accumulo/bin/accumulo init --clear-instance-name --instance-name $ACCUMULO_INSTANCE --password $USERPW
	else
		echo $ZK_HOSTNAME > $INSTALL_DIR/accumulo/conf/monitor
		echo $ZK_HOSTNAME > $INSTALL_DIR/accumulo/conf/gc
		echo $ZK_HOSTNAME > $INSTALL_DIR/accumulo/conf/tracers
		echo $ZK_HOSTNAME > $INSTALL_DIR/accumulo/conf/masters
		hostname > $INSTALL_DIR/accumulo/conf/slaves
	fi

	# EMR starts worker instances first so there will be timing issues
	# Test to ensure it's safe to continue before attempting to start things up
	if is_master ; then
		echo "configuring accumulo - wating for is_accumulo_initialized..."
		with_backoff is_accumulo_initialized
	else
		echo "configuring accumulo - wating for is_accumulo_available..."
		with_backoff is_accumulo_available
	fi

	echo "configuring accumulo - start accumulo"
	$INSTALL_DIR/accumulo/bin/start-here.sh
	echo "configuring accumulo - done"
}

is_zookeeper_initialized() {
	/usr/lib/zookeeper/bin/zkServer.sh status
	return $?
}

is_accumulo_initialized() {
	hadoop fs -ls /accumulo/instance_id
	return $?
}

is_accumulo_available() {
	$INSTALL_DIR/accumulo/bin/accumulo info
	return $?
}

# Settings recommended for Accumulo
os_tweaks() {
	echo "os_tweaks - start"
	echo -e "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee --append /etc/sysctl.conf
	echo -e "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee --append /etc/sysctl.conf
	echo -e "net.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee --append /etc/sysctl.conf
	echo -e "vm.swappiness = 0" | sudo tee --append /etc/sysctl.conf
	echo -e "fs.file-max = 65536" | sudo tee --append /etc/sysctl.conf
	sudo sysctl -w vm.swappiness=0
	echo -e "" | sudo tee --append /etc/security/limits.conf
	echo -e "*\t\tsoft\tnofile\t65536" | sudo tee --append /etc/security/limits.conf
	echo -e "*\t\thard\tnofile\t65536" | sudo tee --append /etc/security/limits.conf
	sudo /sbin/sysctl -p

	echo "os_tweaks - yum install mlocate"
	sudo yum install mlocate -y
	sudo updatedb
	echo "os_tweaks - done"
}
