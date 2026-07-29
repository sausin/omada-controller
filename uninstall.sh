#!/bin/bash
NAME="omada"
DESC="Omada Network Application"

DEST_DIR=/opt/tplink
DEST_FOLDER=EAPController
INSTALLDIR=${DEST_DIR}/${DEST_FOLDER}
WORKDIR=${INSTALLDIR}/work
#INSTALLDIR=$(dirname $(readlink -f $0))
LINK=/etc/init.d/tpeap
LINK_CMD=/usr/bin/tpeap
CLUSTER_LINK_CMD=/usr/bin/omadacluster


MAIN_CLASS="com.tplink.smb.omada.starter.OmadaLinuxMain"
V4_MAIN_CLASS="com.tplink.omada.start.OmadaLinuxMain"

#Define the variable to judge that if
#the execution of uninstall.sh is for upgrading.
UNINSTALL_TYPE=$1

user_confirm() {
    if [ "${UNINSTALL_TYPE}" == "upgrade" ]; then
               return 0
    fi

    if [ "${UNINSTALL_TYPE}" == "-y" -o "${UNINSTALL_TYPE}" == "-Y" ]; then
               return 0
    fi

    while true
    do
        echo -n "${DESC} will be uninstalled from [${INSTALLDIR}] (y/n): "
        read input
        confirm=`echo $input | tr '[a-z]' '[A-Z]'`

        if [ "$confirm" == "Y" -o "$confirm" == "YES" ]; then
            return 0
        elif [ "$confirm" == "N" -o "$confirm" == "NO" ]; then
            return 1
        fi
    done
}


user_keep_db() {
    if [ "${UNINSTALL_TYPE}" == "upgrade" ]; then
               return 0
    fi

    if [ "${UNINSTALL_TYPE}" == "-y" -o "${UNINSTALL_TYPE}" == "-Y" ]; then
        return 0
    fi

    while true
    do
        CLUSTER_HS_DIR=${INSTALLDIR}/data/cluster/hsConfig
        if [ -d "${CLUSTER_HS_DIR}" ]; then
            echo -n "Do you want to retain the current database [${INSTALLDIR}/data/db] ? This database does not affect the external Mongo database (y/n): "
        else
            echo -n "Do you want to backup database [${INSTALLDIR}/data/db] (y/n): "
        fi

        read input
        confirm=`echo $input | tr '[a-z]' '[A-Z]'`

        if [ "$confirm" == "Y" -o "$confirm" == "YES" ]; then
            return 0
        elif [ "$confirm" == "N" -o "$confirm" == "NO" ]; then
            return 1
        fi
    done
}

# return: 0, exist; 1, not exist;
link_exist() {
    if test -x $1; then
        if [ ${INSTALLDIR}/bin/control.sh = $(readlink -f $1) ]; then
            return 0
        fi
    fi

    return 1
}

# return: 1,running; 0, not running;
is_running() {
    [ -z "$(pgrep -f ${MAIN_CLASS})" -a -z "$(pgrep -f ${V4_MAIN_CLASS})" ] && {
        return 0
    }

    return 1
}

# root permission check
check_perms() {
    [ $(id -ru) != 0 ] && { echo "You must be root to uninstall the ${DESC}. Exit." 1>&2; exit 1; }
}
# do uninstall, remove link,service,install dir
do_uninstall() {
    echo "do uninstall..."
    BACKUP_FOLDER=${INSTALLDIR}/../omada_db_backup
    DB_FILE_NAME=omada.db.tar.gz

    if [ $NEED_KEEP_DB == 1 ]; then
      mkdir $BACKUP_FOLDER > /dev/null 2>&1
      cd ${INSTALLDIR}/data
      tar zcvf $DB_FILE_NAME db
      cp -f $DB_FILE_NAME $BACKUP_FOLDER/
      chmod 600 ${BACKUP_FOLDER}/${DB_FILE_NAME}
    fi

    rm -rf ${INSTALLDIR}
}

# do upgrade, remove work dir and so on, keep data dir
do_upgrade() {
    # echo "do upgrade, remove work dir"
    rm -rf ${WORKDIR}
    # echo "do upgrade, remove other dir"
    rm -rf ${INSTALLDIR}/bin
    rm -rf ${INSTALLDIR}/lib
    rm -rf ${INSTALLDIR}/webapp

    return 0;

}


# root permission check
check_perms

# user confirm
if ! user_confirm; then
    exit
fi

NEED_KEEP_DB=0

if ! user_keep_db; then
    NEED_KEEP_DB=0
else
    NEED_KEEP_DB=1
fi

echo "========================"

if [ "${UNINSTALL_TYPE}" != "upgrade" ]; then
    echo "Uninstallation start ..."
fi


link_exist ${LINK}
exist=$?
count=0
while [ $exist -eq 1 ]
do
    count=`expr ${count} + 1`
    link_exist ${LINK}${count}
    exist=$?
    if [ $count -gt 100 ]; then
        # not found LINK
        break;
    fi
done


for i in `seq 1 3` ; do
    is_running
    [ 0 == $? ] && {
        break
    }

    echo "${DESC} is running, going to stop it."
    if [ -x ${INSTALLDIR}/bin/control.sh ]; then
        ${INSTALLDIR}/bin/control.sh stop
    else
        echo "Can't stop ${DESC}! You should stop it by yourself before uninstall."
        exit
    fi

    sleep 3
done

# removing
if [ $count -eq 0 ]; then
    link_name=${LINK}
    link_cmd_name=${LINK_CMD}
    cluster_link_cmd_name=${CLUSTER_LINK_CMD}
else
    link_name=${LINK}${count}
    link_cmd_name=${LINK_CMD}${count}
    cluster_link_cmd_name=${CLUSTER_LINK_CMD}${count}
fi

update-rc.d $(basename ${link_name}) remove 2>/dev/null
result=$?
if [ $result -ne 0 ]; then
    chkconfig --del ${link_name}
    chkconfig --del ${link_cmd_name}
    chkconfig --del ${cluster_link_cmd_name}
fi

rm ${link_name}
rm ${link_cmd_name}
rm ${cluster_link_cmd_name}

if [ "${UNINSTALL_TYPE}" == "upgrade" ]; then
   do_upgrade
   else
   do_uninstall
fi

if [ "${UNINSTALL_TYPE}" != "upgrade" ]; then
   echo "Uninstall ${DESC} successfully."
fi
