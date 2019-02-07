#!/usr/bin/env bash
#
# Bootstrap an Accumulo cluster node
#
# Credit for this script belongs to https://github.com/locationtech/geowave and http://s3.amazonaws.com/geowave/0.9.4.1/docs/quickstart.html 
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# I've externalized commands into library functions for clarity, download and source
if [ ! -f /tmp/accumulo-install-lib.sh ]; then
	aws s3 cp s3://prometheus-emr-scripts/accumulo-install-lib.sh /tmp/accumulo-install-lib.sh
fi
source /tmp/accumulo-install-lib.sh

# The EMR customize hooks run _before_ everything else, so Hadoop is not yet ready
THIS_SCRIPT="$(realpath "${BASH_SOURCE[0]}")"
RUN_FLAG="${THIS_SCRIPT}.run"
# On first boot skip past this script to allow EMR to set up the environment. Set a callback
# which will poll for availability of HDFS and then install Accumulo
if [ ! -f "$RUN_FLAG" ]; then
	touch "$RUN_FLAG"
	TIMEOUT= is_master && TIMEOUT=3 || TIMEOUT=4
	echo "bash -x $(realpath "${BASH_SOURCE[0]}") > /tmp/accumulo-install.log" | at now + $TIMEOUT min
	exit 0 # Bail and let EMR finish initializing
fi

# Get Accumulo running
os_tweaks && configure_zookeeper
install_accumulo && configure_accumulo
