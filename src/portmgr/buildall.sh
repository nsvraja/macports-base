#!/bin/sh

# Author: Jordan K. Hubbard
# Date: 2004/12/10
#
# Declare all the various shell functions which do the heavy lifting.
# If you want to see the main body of this script, go to the end of the file.

# What we want to call the base chroot images
CHROOTBASE=chrootbase.sparseimage
DISTFILES=distfiles.dmg
FSTYPE=HFSX

# Some conservative (and large) defaults.
BASE_PADDING=4000000
DISTFILES_SIZE=8192M

# deal with fatal errors
bomb() {
	echo "Error: $*"
	echo "BASEDEV=${BASEDEV} DISTDEV=${DISTDEV}"
	exit 1
}

# Everything we need to create the base chroot disk image (populated from host)
mkchrootbase() {
	if [ -f ${CHROOTBASE} ]; then
		echo "Using existing ${CHROOTBASE} for efficiency"
	else
		dir=$1
		mkdir -p $dir

		# Add to this list as you find minimum dependencies DP really needs.
		chrootfiles="bin sbin etc tmp var private dev/null usr Developer System/Library Library/Java"

		echo "Calculating chroot base image size..."
		# start with this size to account for other overhead
		sz=${BASE_PADDING}
		for i in $chrootfiles; do
			mysz=`cd /; du -sk $i |awk '{print $1}'`
			sz=$(($sz + $mysz))
		done
		echo "Creating bootstrap disk image of ${sz}K bytes"
		hdiutil create -size ${sz}k -fs ${FSTYPE} -volname base ${CHROOTBASE} > /dev/null
		BASEDEV=`hdiutil attach ${CHROOTBASE} -mountpoint $dir 2>&1 | awk '/dev/ {if (x == 0) {print $1; x = 1}}'`
		echo "Image attached as $BASEDEV"
		echo "Copying chroot files into bootstrap disk image"
		for i in $chrootfiles; do
			pax -pe -rw /$i $dir 2>/dev/null
			# special case for pax
			cp /bin/pax $dir/bin/pax
		done
		# special case nuke to prevent builder pollution
		rm -rf $dir/usr/X11R6
		if [ -f darwinports.tar.gz ]; then
			echo "Found darwinports.tar.gz - copying into chroot"
			tar -xpzf darwinports.tar.gz -C $dir
		elif [ -d darwinports ]; then
			pax -rw darwinports $dir
		else
			echo "no darwinports.tar.gz or darwinports directory found - please fix this and try again."
			exit 1
		fi
		bootstrapdports $dir
	fi
	if [ -f ${DISTFILES} ]; then
		echo "Using existing ${DISTFILES} for efficiency"
	else
		echo "Creating distfiles cache of size ${DISTFILES_SIZE}"
		hdiutil create -size ${DISTFILES_SIZE} -fs ${FSTYPE} -volname distfiles ${DISTFILES} > /dev/null
	fi
}

bootstrapdports() {
	dir=$1
	cat > $dir/bootstrap.sh << EOF
#!/bin/sh
cd darwinports/base
./configure
make all install
make clean
sed -e "s;portautoclean.*yes;portautoclean no;" < /etc/ports/ports.conf > /etc/ports/ports.conf.new && mv /etc/ports/ports.conf.new /etc/ports/ports.conf
EOF
	if [ "$PKGTYPE" = "dpkg" ]; then
	    echo "/opt/local/bin/port install dpkg" >> $dir/bootstrap.sh
	fi
	chmod 755 $dir/bootstrap.sh
	echo "Bootstrapping darwinports in chroot"
	/sbin/mount_devfs devfs ${dir}/dev
	/sbin/mount_fdesc -o union fdesc ${dir}/dev
	chroot $dir /bootstrap.sh && rm $dir/bootstrap.sh
	umount ${dir}/dev
	umount ${dir}/dev
	hdiutil detach $BASEDEV >& /dev/null && BASEDEV=""
}

# Set up the base chroot image
prepchroot() {
	dir=$1
	if [ $STUCK_BASEDEV = 0 ]; then
		rm -f ${CHROOTBASE}.shadow
		BASEDEV=`hdiutil attach ${CHROOTBASE} -mountpoint $dir -readonly -shadow 2>&1 | awk '/dev/ {if (x == 0) {print $1; x = 1}}'`
		mkdir -p $dir/.vol
	fi
 	DISTDEV=`hdiutil attach ${DISTFILES} -mountpoint $dir/opt/local/var/db/dports/distfiles -union 2>&1 | awk '/dev/ {if (x == 0) {print $1; x = 1}}'`
	/sbin/mount_devfs devfs $dir/dev || bomb "unable to mount devfs"
	/sbin/mount_fdesc -o union fdesc $dir/dev || bomb "unable to mount fdesc"
}

# Undo the work of prepchroot
teardownchroot() {
	dir=$1
	umount $dir/dev  || bomb "unable to umount devfs"
	umount $dir/dev  || bomb "unable to umount fdesc"
	[ -z "$DISTDEV" ] || (hdiutil detach $DISTDEV >& /dev/null || bomb "unable to detach DISTDEV")
	DISTDEV=""
	if [ ! -z "$BASEDEV" ]; then
		if hdiutil detach $BASEDEV >& /dev/null; then
			STUCK_BASEDEV=0
			BASEDEV=""
		else
			echo "Warning: Unable to detach BASEDEV ($BASEDEV)"
			STUCK_BASEDEV=1
		fi
	fi
}

# main:  This is where we start the show.
TGTPORTS=""
PKGTYPE=mpkg

if [ $# -lt 1 ]; then
	echo "Usage: $0 chrootdir [-p pkgtype] [targetportsfile]"
	exit 1
else
	DIR=$1
	shift
	if [ $# -gt 1 ]; then
		if [ $1 = "-p" ]; then
		    shift
		    PKGTYPE=$1
		    shift
		fi
	fi
	if [ $# -gt 0 ]; then
		TGTPORTS=$1
	fi
fi

rm -rf outputdir
if [ -z "$TGTPORTS" ]; then
	if [ -f PortIndex ]; then
		PINDEX=PortIndex
	elif [ -f darwinports/dports/PortIndex ]; then
		PINDEX=darwinports/dports/PortIndex
	else
		echo "I need a PortIndex file to work from - please put one in the"
		echo "current directory or unpack a darwinports distribution to get it from"
		exit 1
	fi
	mkdir -p outputdir/summary
	TGTPORTS=outputdir/summary/portsrun
	awk 'NF == 2 {print $1}' $PINDEX > $TGTPORTS
fi

mkchrootbase $DIR
mkdir -p outputdir/Packages outputdir/logs/succeeded outputdir/logs/failed outputdir/tmp
# Hack to work around sticking volfs problem.
STUCK_BASEDEV=0

echo "Starting packaging run for `wc -l $TGTPORTS | awk '{print $1}'` ports."
for pkg in `cat $TGTPORTS`; do
	prepchroot $DIR
	echo "Starting packaging run for $pkg"
	echo "#!/bin/sh" > $DIR/bootstrap.sh
	echo 'export PATH=$PATH:/opt/local/bin' >> $DIR/bootstrap.sh
	echo '/sbin/mount_volfs /.vol' >> $DIR/bootstrap.sh
	echo "mkdir -p /Package" >> $DIR/bootstrap.sh
	echo "rm -f /tmp/success" >> $DIR/bootstrap.sh
	echo "if port -v $PKGTYPE $pkg package.destpath=/Package >& /tmp/$pkg.log; then touch /tmp/success; fi" >> $DIR/bootstrap.sh
	echo 'umount /.vol || (echo "unable to umount volfs"; exit 1)' >> $DIR/bootstrap.sh
	echo "exit 0" >> $DIR/bootstrap.sh
	chmod 755 $DIR/bootstrap.sh
	chroot $DIR /bootstrap.sh || bomb "bootstrap script in chroot returned failure status"
	if [ ! -f $DIR/tmp/success ]; then
		echo $pkg >> outputdir/summary/portsfailed
		type="failed"
	else
		echo $pkg >> outputdir/summary/portspackaged
		if [ "$PKGTYPE" = "mpkg" ]; then
		    mv $DIR/Package/*.mpkg outputdir/Packages/
		elif [ "$PKGTYPE" = "dpkg" ]; then
		    mv $DIR/Package/*.deb outputdir/Packages/
		fi
		type="succeeded"
	fi
	mv $DIR/tmp/$pkg.log outputdir/logs/$type
	teardownchroot $DIR
	echo "Finished packaging run for $pkg ($type)"
done
echo "Packaging run complete."
exit 0
