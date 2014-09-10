#!/bin/bash
# Create: 2014-05-02 John C. Petrucci
# Purpose: Finds rotated firewall logs and transfers them off box.  Deletes files to free disk space.
# Usage: ./script [-v]
#    -v         Verbose mode
#    -h         Display help
# Execute on Check Point SMS/CMA/CLM.  Intended to be run from cron but also works ad-hoc.
#
# Begin variables.  Tweak as necessary.
archive_name="$(\date -d YESTERDAY '+%F').tgz" # Naming convention for the archive of logs.
sftp_user="user"
sftp_host="charliehost.jcp"
sftp_id="/home/admin/.ssh/id_rsa"
# End variables.  Do not modify below.

me=$(basename "$0")
. /opt/CPshared/5.0/tmp/.CPprofile.sh # Source Check Point environment.

if ! tty >/dev/null; then # If running non-interactively such as from cron then send output to logs.
        exec > >(logger -t "$me")
        exec 2>&1
fi

verbosity=2 # Start counting at 2 so that any increase to this will result in a minimum of file descriptor 3.
maxverbosity=3 # The highest verbosity we use / allow to be displayed.

# Begin functions.
showHelp() { # Function to display help message.
	awk '/^# Create/,/^#$/' "$0" | sed 's/#//'
}

{ # Parse arguments for flexible verbosity handling and help text.
	while getopts ":v" opt; do
		case $opt in
			v)  (( verbosity=verbosity+1 ))
			;;
			*)	showHelp; exit 0
			;;
		esac
	done

	for v in $(seq 3 $verbosity) # Start counting from 3 since 1 and 2 are standards (stdout/stderr).
	do
		(( "$v" <= "$maxverbosity" )) && eval exec "$v>&2"  # Don't change anything higher than the maximum verbosity allowed.
	done

	for v in $(seq $(( verbosity+1 )) $maxverbosity ) # From the verbosity level one higher than requested, through the maximum;
	do
		(( "$v" > "2" )) && eval exec "$v>/dev/null" # Redirect these to bitbucket, provided that they don't match stdout and stderr.
	done
}

removeLogs() { # Function to remove logs and log archive after they are transferred.
	status="$1"
	printf "%s\n" "Removing log archive." >&3
	\rm -vf "$archive_name" >&3
	
	if [[ $status == "success" ]]; then # We only remove logs if the upload succeeded.  Log archives are removed regardless.
		printf "%s\n" "Removing logs." >&3
		\rm -vf "${log_array[@]}" >&3
	fi
}

summaryQuit() { # Function to show message about activity and then exit with specified exit code.
	if [[ $1 == 0 ]]; then # If non-problematic exit then show report of disk space.
		diskusage="$diskusage
		
Disk usage after run:
$(df -h .)"
		printf "%s\n" "$diskusage" >&3
	fi

	printf "%s\n" "$me exiting with status ${1}.  ${2:-Run in verbose mode for more information.}" # If the call to quit did not give a description then give this generic message.
	exit $1
}
#End functions.

printf "%s\n" "Changing to log directory." >&3
cd $FWDIR/log/ || summaryQuit 1 "Failed to find log directory."

diskusage="Disk usage before run:
$(df -h .)" # Store the disk usage before moving logs.

printf "%s\n" "Building list of logs to archive." >&3
log_array=($(find . -maxdepth 1 -regextype posix-egrep -type f -regex ".*/[0-9]{4}(\-[0-9]{2}){2}_[0-9]{6}\.log(_stats|(account_|initial_)?ptr)?" -cmin +60 -print)) # Find all files that look like firewall logs and have not been changed in last 60 minutes.
[[ -n "$log_array" ]] || summaryQuit 0 "No log files eligible for archive." # Quit if nothing needs archived.

printf "%s\n" "Generating checksums of logs." >&3
md5sum "${log_array[@]}" >&3

printf "%s\n" "Archiving logs." >&3
tar czf "$archive_name" "${log_array[@]}" || { removeLogs fail; summaryQuit 1 "Archive generation failed."; } # If we fail to create tgz then quit.

printf "%s\n" "Uploading log archive." >&3
sftp -o IdentityFile="$sftp_id" "$sftp_user"@"$sftp_host" -b <<EOF 2>&3 >&3
cd sftp-logs
put $archive_name
dir
bye
EOF

case "$?" in
	0)	printf "%s\n" "SFTP upload succeeded." >&3;
		removeLogs success; summaryQuit 0 "SFTP upload succeeded.";
		;;
	*)	printf "%s\n" "SFTP upload failed." >&2;
		removeLogs fail; summaryQuit $?;
		;;
esac
