#!/bin/bash
#
# osx-backup.sh
#
# Backup script for Mac OS X 10.8 Server
#
# Edit history
# 20120506 - LG: First draft
# 20120507 - JE: Enhancements, OS version check, services check.
# 20120507 - AB: Textedit bug fix, lockfile creation fix, fatal() fix, date stamp escape fix.
# 20120509 - AB: Bugfix for truncated log file in wiki backup. Added service status test & conditional restart
# 20120513 - AB: Added OD backup, services .plist backup.
# 20130407 - JE: Updated script for OSX Server Wiki Service
# 20130407 - AB: Added check for Mac OS X 10.8. Shouldn't run on anything else.
# 20130415 - AB: Fixed version check.
# 20130416 - JE: Specified serveradmin path as variable, moved OD_BACKUP variable, removed debug flag
# 20131025 - JE: Changed device_management user to _devicemgr 
# 20140221 - JE: Added DNS backup service

export DATESTAMP=`date +%Y-%m-%d`

### WHAT DO YOU WANT TO BACKUP? ###

DEVICEMGR=NO
WIKI=YES
WEBMAIL=NO
CALDAV=NO
POSTGRES=NO
OPENDIR=YES
SERVICE_PLISTS=YES
DNS=YES

### VARIABLES  ###

BACKUP_LOCATION="/Users/admin/Desktop"
PASSWD="password"
LOGFILE=/var/log/osx_backup.log
SERVERADMIN="/Applications/Server.app/Contents/ServerRoot/usr/sbin/serveradmin"

# You can either backup all of the services (even those not in use)
# or you can specify which services you want to backup.
SERVICES=`serveradmin list`

OS_VER_MAJ=$(sw_vers -productVersion | cut -c 1-4)

### You probably shouldn't edit below this line ####
#
# Timestamp the log file.
echo "Backup job started:" `date +%Y-%m-%d\ %H:%M` >> $LOGFILE

# Check Mac OS X version. Needs to be 10.8.
if [ $OS_VER_MAJ = 10.8 ]; then
        echo "This is a 10.8 system." >> $LOGFILE
else
        echo "This only runs on Mac OS 10.8. Exiting..." >> $LOGFILE
        exit 1
fi

# Cleans up the pid file and extra backups
function cleanup {
	echo "Cleaning up..." >> $LOGFILE
    rm $BACKUP_LOCATION/lockfile

	# keep weekly backup
	if [`find $BACKUP_LOCATION -maxdepth 1 -type f -mtime -2 -name "20*" | wc -l` -gt 7 ]; then
		echo "FOUND! Weekly retention" >> $LOGFILE
		OLDEST=`ls -1 -tr $BACKUP_PATH | head -1` 
		if [ ! -d $BACKUP_PATH/$OLDEST $BACKUP_PATH/WEEKLY ]; then
			mkdir -p $BACKUP_PATH/$OLDEST $BACKUP_PATH/WEEKLY || fatal "could not make WEEKLY folder"
		fi
		if `mv $BACKUP_PATH/$OLDEST $BACKUP_PATH/WEEKLY`; then
			rm -rf $BACKUP_PATH/20* &> $LOGFILE
		fi
	fi
	echo "Cleanup is done!" >> $LOGFILE
}

# Fatal error function
function fatal {
    echo "$0: fatal error: $@" >> $LOGFILE
    cleanup
    exit 1
}

function is_service_running {
	STATUS=$(sudo serveradmin status $1 2> /dev/null | awk '/.*:state/{print $NF;exit}')
	if [ $STATUS == '"RUNNING"' ]; then
		return 0
	else
		return 1
	fi
}

function check_postgres {
        /usr/bin/sudo -u _postgres /Applications/Server.app/Contents/ServerRoot/usr/bin/pg_ctl status -D /Library/Server/PostgreSQL\ For\ Server\ Services/Data >> /dev/null
        retval=$?
        
        if [ $retval -ne 0 ]; then
                echo "Postgres is not running, launch postgres..." >> $LOGFILE
                sudo -u _postgres /Applications/Server.app/Contents/ServerRoot/usr/bin/postgres_real -D /Library/Server/PostgreSQL\ For\ Server\ Services/Data -c listen_addresses= -c log_connections=on -c log_directory=/Library/Logs/PostgreSQL -c log_filename=PostgreSQL_Server_Services.log -c log_line_prefix=%t  -c log_lock_waits=on -c log_statement=ddl -c logging_collector=on -c unix_socket_directory=/Library/Server/PostgreSQL\ For\ Server\ Services/Socket -c unix_socket_group=_postgres -c unix_socket_permissions=0770 &            
                pidval=$!
				sleep 5
        fi
}

# Check to see if backup location exists, if not, create it. 
if [ ! -d $BACKUP_LOCATION ]; then 
	echo "Looks like a first run for $BACKUP_LOCATION" >> $LOGFILE
	mkdir -p $BACKUP_LOCATION || fatal "could not create backup location"
fi

if [ ! -d $BACKUP_LOCATION/$DATESTAMP ]; then
	mkdir -p $BACKUP_LOCATION/$DATESTAMP || fatal "could not create backup location"
fi

# check and create lockfile
if [ -f $BACKUP_LOCATION/lockfile ]
	then
	echo “Lockfile exists, backup stopped.” >> $LOGFILE
	exit 2
else
	echo "Creating the lockfile at $BACKUP_LOCATION" >> $LOGFILE
	touch $BACKUP_LOCATION/lockfile
fi

# Backup DNS Service
if [ $DNS == "YES" ]; then
	if  is_service_running dns  ; then
		RESTART="YES"
		echo "Stopping DNS service..." >> $LOGFILE
		serveradmin stop dns >> $LOGFILE || fatal "could not stop dns"
	else
		RESTART="NO"
	fi
	echo "Backing up DNS database..." >> $LOGFILE
	tar -cvzf $BACKUP_LOCATION/$DATESTAMP/named.tar.gz /var/named || fatal "tarball /var/named"
	cp /etc/named.conf $BACKUP_LOCATION/$DATESTAMP/ || fatal "could copy /etc/named.conf"
	if [ $RESTART == "YES" ]; then
		echo "Starting DNS service..." >> $LOGFILE
		sudo serveradmin start dns || fatal "could not start dns"
	fi
	echo "DNS backup complete" >> $LOGFILE
fi


# Backup Profile Manager
if [ $DEVICEMGR == "YES" ]; then
	if  is_service_running devicemgr  ; then
		RESTART="YES"
		echo "Stopping Profile Manager service..." >> $LOGFILE
		serveradmin stop devicemgr >> $LOGFILE || fatal "could not stop devicemgr"
	else
		RESTART="NO"
	fi
	echo "Backing up Profile Manager database..." >> $LOGFILE
	/Applications/Server.app/Contents/ServerRoot/usr/bin/pg_dump -h "/Library/Server/PostgreSQL For Server Services/Socket" --format=c --compress=9 --blobs --username=_devicemgr --file=$BACKUP_LOCATION/$DATESTAMP/device_management.sql device_management || fatal "could not dump database device_management"
	if [ $RESTART == "YES" ]; then
		echo "Starting Profile Manager service..." >> $LOGFILE
		sudo serveradmin start devicemgr || fatal "could not start devicemgr"
	fi
	echo "Profile Manager backup complete" >> $LOGFILE
fi

# Backup Web Service
if [ $WEBMAIL == "YES" ]; then
	if  is_service_running web  ; then
		RESTART="YES"	
		echo "Stopping Web service..." >> $LOGFILE
		serveradmin stop web >> $LOGFILE || fatal "could not stop web"
	else
		RESTART="NO"
	fi
	echo "Backing up Web service database..." >> $LOGFILE
	/Applications/Server.app/Contents/ServerRoot/usr/bin/pg_dump -h "/Library/Server/PostgreSQL For Server Services/Socket" --format=c --compress=9 --blobs --username=roundcubemail --file=$BACKUP_LOCATION/$DATESTAMP/roundcubemail.pgdump roundcubemail || fatal "could not backup database roundcubemail"
	if [ $RESTART == "YES" ]; then
		echo "Starting Web service..." >> $LOGFILE
		serveradmin start web >> $LOGFILE || fatal "could not start web service"
	fi
	echo "Web service backup complete" >> $LOGFILE
fi

# Backup Wiki
if [ $WIKI == "YES" ]; then
	if  is_service_running wiki; then
		RESTART="YES"	
		echo "Stopping Wiki service..." >> $LOGFILE
		serveradmin stop wiki >> $LOGFILE || fatal "could not stop wiki"
		
	else
		RESTART="NO"
	fi
	
	check_postgres
	
	echo "Backing up Wiki service database..."  >> $LOGFILE
	/Applications/Server.app/Contents/ServerRoot/usr/bin/pg_dump -h "/Library/Server/PostgreSQL For Server Services/Socket" --format=c --compress=9 --blobs --username=collab --file=$BACKUP_LOCATION/$DATESTAMP/collab.pgdump collab || fatal "could not backup database collab"
	echo "Copying binary files" >> $LOGFILE
	tar -cvzf $BACKUP_LOCATION/$DATESTAMP/wiki-filedata.tar.gz /Library/Server/Wiki 2>> $LOGFILE 1>/dev/null
	if [ $RESTART == "YES" ]; then	
		echo "Starting Wiki service..." >> $LOGFILE
		serveradmin start wiki >> $LOGFILE || fatal "could not start wiki service"
	fi
	echo "Wiki service backup complete!" >> $LOGFILE
fi

# Backup AddressBook Server and Calendar Server
if [ $CALDAV == "YES" ]; then
	if  is_service_running addressbook  ; then
		RESTART="YES" # Note: assumption that if addressbook is running and needs backup, so does calendar.
		echo "Stopping Address Book and Calendar services..." >> $LOGFILE
		serveradmin stop addressbook >> $LOGFILE || fatal "could not stop addressbook"
		serveradmin stop calendar >> $LOGFILE || fatal "could not stop calendar"
	else
		RESTART="NO"
	fi
	echo "Backing up Address Book and Calendar services..."
	/Applications/Server.app/Contents/ServerRoot/usr/bin/pg_dump -h "/Library/Server/PostgreSQL For Server Services/Socket" --format=c --compress=9 --blobs --username=caldav --file=$BACKUP_LOCATION/$DATESTAMP/caldav.sql caldav || fatal "could not backup database caldav"
	if [ $RESTART == "YES" ]; then	
		echo "Starting Address Book and Calendar..." >> $LOGFILE
		serveradmin start addressbook >> $LOGFILE || fatal "could not start addressbook service"
		serveradmin start calendar >> $LOGFILE || fatal "could not start calendar service"
	fi
	echo "Address Book and Calendar services backup complete!" >> $LOGFILE
fi

# Backup Postgres DB
if [ $POSTGRES == "YES" ]; then
	echo "Backing up the Postgres database itself..." >> $LOGFILE
	/Applications/Server.app/Contents/ServerRoot/usr/bin/pg_dump -h "/Library/Server/PostgreSQL For Server Services/Socket" --format=c --compress=9 --blobs --username=postgres --file=$BACKUP_LOCATION/$DATESTAMP/postgres.sql postgres || fatal "could not backup database postgres"
	echo "Postgres database backup complete!" >> $LOGFILE
	echo "Backup job complete!" >> $LOGFILE
fi

# Backup Open Directory
if [ $OPENDIR == "YES" ]; then
	OD_BACKUP=$BACKUP_LOCATION/OD_backup
	touch $OD_BACKUP
	echo "Backing up Open Directory..." >> $LOGFILE
	echo "dirserv:backupArchiveParams:archivePassword = $PASSWD" > $OD_BACKUP
	echo "dirserv:backupArchiveParams:archivePath = $BACKUP_LOCATION/$DATESTAMP/od_$DATESTAMP" >> $OD_BACKUP
	echo "dirserv:command = backupArchive" >> $OD_BACKUP
	echo "" >> $OD_BACKUP

	$SERVERADMIN command < $OD_BACKUP
	
	rm -f $OD_BACKUP
	echo "Open Directory backup complete!" >> $LOGFILE
fi

# Backup server config .plist files.
if [ $SERVICE_PLISTS == "YES" ]; then
	# Check if services backup location exists, if not, create it. 
	if [ ! -d $BACKUP_LOCATION/$DATESTAMP/services ]; then
		echo "Creating Services plist backup location..." >> $LOGFILE
		mkdir -p $BACKUP_LOCATION/$DATESTAMP/services || fatal "could not create services backup location"
	fi

	echo "Backing up Services plists..." >> $LOGFILE
	for SERVICE in $SERVICES; do
    	serveradmin -x settings $SERVICE > $BACKUP_LOCATION/$DATESTAMP/services/$SERVICE.plist
		sleep 1
	done
       
	echo "Tarring the Services plists..." >> $LOGFILE
	tar -cvzf $BACKUP_LOCATION/$DATESTAMP/service_plists.tar.gz $BACKUP_LOCATION/$DATESTAMP/services 2>> $LOGFILE 1>/dev/null
	rm -rf $BACKUP_LOCATION/$DATESTAMP/services
       
	echo "Services plist backup complete!" >> $LOGFILE
fi

cleanup

echo "Backup job is complete!" >> $LOGFILE
