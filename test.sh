#!/usr/bin/env bash

set -e

while getopts "g" opt
do
    case ${opt} in
        "g")
            set -x
            ;;
        \?)
        echo "Invalid option: -$OPTARG" >&2
        exit -1
        ;;
    esac
done


mysql_user="`whoami`"
mysql_password=""
mysql_host="localhost"
mysql_db="sakila"
work_dir="/tmp/recovery_$RANDOM"
top_dir="`pwd`"

# Check that the script is run from source directory
if ! test -f "$top_dir/stream_parser.c"
then
	echo "Script $0 must be run from a directory with TwinDB InnoDB Recovery Tool source code"
	exit 1
fi

echo -n "Initializing working directory... "
if test -d "$work_dir"
then
	echo "Directory $work_dir must not exist. Remove it and restart $0"
	exit 1
fi

mkdir "$work_dir"
cd "$work_dir"
trap "if [ $? -ne 0 ] ; then rm -r \"$work_dir\"; fi" EXIT
echo "OK"


echo -n "Downloading sakila database... "
tar zxf "$top_dir"/sakila/sakila-db.tar.gz
echo "OK"

echo -n "Testing MySQL connection... "
if test -z "$mysql_password"
then
	MYSQL="mysql -u$mysql_user -h $mysql_host"
else
	MYSQL="mysql -u$mysql_user -p$mysql_password -h $mysql_host"
fi
${MYSQL} -e "SELECT COUNT(*) FROM user" mysql >/dev/null
has_innodb=`${MYSQL} -e "SHOW ENGINES"| grep InnoDB| grep -e "YES" -e "DEFAULT"`
if test -z "$has_innodb"
then
	echo "InnoDB is not enabled on this MySQL server"
	exit 1
fi
echo "OK"

echo -n "Creating sakila database... "
${MYSQL} -e "CREATE DATABASE IF NOT EXISTS $mysql_db"
${MYSQL} -e "CREATE DATABASE IF NOT EXISTS ${mysql_db}_recovered"
${MYSQL} -f ${mysql_db} < sakila-db/sakila-schema.sql 2> /dev/null || true
${MYSQL} ${mysql_db} < sakila-db/sakila-data.sql
echo "OK"

echo -n "Waiting till MySQL flushes everything on disk... "
# Wait till all pages are flushed on disk
timeout=300
lsn=`${MYSQL} -NB -e "SHOW ENGINE INNODB STATUS\G"| grep "Log sequence number"| awk '{ print $NF}'`
lsn_checkpoint=`${MYSQL} -NB -e "SHOW ENGINE INNODB STATUS\G"| grep "Last checkpoint at"| awk '{ print $NF}'`
while [ ${lsn} -gt ${lsn_checkpoint} ]
do
	lsn_checkpoint=`${MYSQL} -NB -e "SHOW ENGINE INNODB STATUS\G"| grep "Last checkpoint at"| awk '{ print $NF}'`
	sleep 1
	timeout=$((${timeout} - 1))
	if [ ${timeout} -lt 0 ]; then echo "Timeout expired"; exit ; fi
done
echo "OK"

echo -n "Counting sakila tables checksums... "
tables=`${MYSQL} -NB -e "SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA='$mysql_db' and ENGINE='InnoDB'" information_schema`
i=0
for t in ${tables}
do
	checksum[${i}]=`${MYSQL} -NB -e "CHECKSUM TABLE $t" ${mysql_db} | awk '{ print $2}'`
	let i=${i}+1
done
echo "OK"

echo -n "Building InnoDB parsers... "
cd "$top_dir"
make clean all > "$work_dir/make.log" 2>&1
cd "$work_dir"
echo "OK"

# Get datadir
datadir="`${MYSQL}  -e "SHOW VARIABLES LIKE 'datadir'" -NB | awk '{ $1 = ""; print $0}'| sed 's/^ //'`"
innodb_file_per_table=`${MYSQL}  -e "SHOW VARIABLES LIKE 'innodb_file_per_table'" -NB | awk '{ print $2}'`
innodb_data_file_path=`${MYSQL}  -e "SHOW VARIABLES LIKE 'innodb_data_file_path'" -NB | awk '{ $1 = ""; print $0}'| sed 's/^ //'`

echo "Splitting InnoDB tablespace into pages... "
old_IFS="$IFS"
IFS=";"
for ibdata in ${innodb_data_file_path}
do
	ibdata_file=`echo ${ibdata} | awk -F: '{print $1}'`
	"$top_dir"/stream_parser -f "$datadir/$ibdata_file"
done
IFS=${old_IFS}
if [ ${innodb_file_per_table} == "ON" ]
then
	for t in ${tables}
	do
		"$top_dir"/stream_parser -f "$datadir/$mysql_db/$t.ibd"
	done
fi
echo "OK"

echo -n "Recovering InnoDB dictionary... "
old_IFS="$IFS"
IFS=";"
for ibdata in ${innodb_data_file_path}
do
	ibdata_file=`echo ${ibdata} | awk -F: '{print $1}'`
	dir="pages-$ibdata_file"/FIL_PAGE_INDEX/`printf "%016d" 1`.page
	mkdir -p "dumps/${mysql_db}_recovered"
	if test -f "$dir"
	then
		"$top_dir"/c_parser -Uf "$dir" -p "${mysql_db}_recovered" \
            -t "$top_dir"/dictionary/SYS_TABLES.sql 2>SYS_TABLES.sql | sort -nk 5 \
            > "dumps/${mysql_db}_recovered/SYS_TABLES"
	fi
	dir="pages-$ibdata_file"/FIL_PAGE_INDEX/`printf "%016d" 3`.page
	if test -f "$dir"
	then
		"$top_dir"/c_parser -Uf "$dir" -p "${mysql_db}_recovered" \
        -t "$top_dir"/dictionary/SYS_INDEXES.sql 2>SYS_INDEXES.sql | sort -nk 4,5 \
        > "dumps/${mysql_db}_recovered/SYS_INDEXES" 
	fi

done
IFS=${old_IFS}

${MYSQL} -e "DROP TABLE IF EXISTS SYS_TABLES" ${mysql_db}_recovered 
${MYSQL} -e "DROP TABLE IF EXISTS SYS_INDEXES" ${mysql_db}_recovered 
# load structure
${MYSQL}  ${mysql_db}_recovered < "$top_dir"/dictionary/SYS_TABLES.sql
${MYSQL} ${mysql_db}_recovered < "$top_dir"/dictionary/SYS_INDEXES.sql
# load data
${MYSQL} --local-infile=1 ${mysql_db}_recovered < SYS_INDEXES.sql
${MYSQL} --local-infile=1 ${mysql_db}_recovered < SYS_TABLES.sql
echo "OK"
echo -n "Recovering tables... "
is_56=`${MYSQL} -NB -e "select @@version"| grep -e 5\.6\. -e 5\.7\.|| true`
for t in ${tables}
do
	# get index id
	index_id="`${MYSQL} -NB -e "SELECT SYS_INDEXES.ID FROM SYS_INDEXES JOIN SYS_TABLES ON SYS_INDEXES.TABLE_ID = SYS_TABLES.ID WHERE SYS_TABLES.NAME= '${mysql_db}/$t' ORDER BY SYS_TABLES.ID DESC, SYS_INDEXES.ID LIMIT 1" ${mysql_db}_recovered`"

    C_PARSER_ARG=(-p ${mysql_db}_recovered)

    if ! test -z ${is_56}
    then
        C_PARSER_ARG+=(-6)
    fi


    C_PARSER_ARG+=(-t ${top_dir}/sakila/$t.sql)

	if [ ${innodb_file_per_table} == "ON" ]
	then
	    C_PARSER_ARG+=(-b pages-$t.ibd/FIL_PAGE_TYPE_BLOB)
	    C_PARSER_ARG+=(-f pages-$t.ibd/FIL_PAGE_INDEX/`printf '%016u' ${index_id}`.page)
		"$top_dir"/c_parser "${C_PARSER_ARG[@]}" > "dumps/${mysql_db}_recovered/$t" 2> ${t}.sql
	else
		old_IFS="$IFS"
		IFS=";"
		for ibdata in ${innodb_data_file_path}
		do
			ibdata_file="`echo ${ibdata} | awk -F: '{print $1}'`"
			dir="pages-${ibdata_file}/FIL_PAGE_INDEX/`printf '%016u' ${index_id}`.page"
			C_PARSER_ARG+=(-f ${dir})
			C_PARSER_ARG+=(-b pages-$ibdata_file/FIL_PAGE_TYPE_BLOB)
			if test -f "$dir"
			then
				"$top_dir"/c_parser "${C_PARSER_ARG[@]}" > "dumps/${mysql_db}_recovered/$t" 2> ${t}.sql
			fi

		done
		IFS="$old_IFS"
	fi
done
echo "OK"

echo "Loading recovered data into MySQL:"
for t in ${tables}
do
    s=`printf "%20s" ${t}`
    echo -n "${s} ... "
	${MYSQL} -e "DROP TABLE IF EXISTS \`$t\`;CREATE TABLE $t like ${mysql_db}.$t" ${mysql_db}_recovered
    ${MYSQL} --local-infile=1 ${mysql_db}_recovered < ${t}.sql
    echo "OK"
done

echo "Verifying tables checksum:"
i=0
for t in ${tables}
do
    s=`printf "%20s" ${t}`
    echo -n "${s} ... "
	chksum_recovered=`${MYSQL} -NB -e "CHECKSUM TABLE $t" ${mysql_db}_recovered| awk '{ print $2}'`
	if [ "$chksum_recovered" == ${checksum[${i}]} ]
	then
		echo "OK"
	else
		echo "NOT OK"
	fi
        let i=${i}+1

done

cd "$top_dir"
echo "DONE"
