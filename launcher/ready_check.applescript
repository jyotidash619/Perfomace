on run
	set appBundlePath to POSIX path of (path to me)
	set projectRoot to do shell script "/usr/bin/python3 -c " & quoted form of "import os, sys; print(os.path.abspath(os.path.join(sys.argv[1], '../../..')))" & " " & quoted form of appBundlePath
	set readyCheckPath to projectRoot & "/PerfoMace_Ready_Check.sh"
	
	try
		do shell script "test -f " & quoted form of readyCheckPath
	on error
		display dialog "PerfoMace ready-check script was not found at:" & return & readyCheckPath buttons {"OK"} default button "OK" with icon stop
		return
	end try
	
	set terminalCommand to "cd " & quoted form of projectRoot & " && bash ./PerfoMace_Ready_Check.sh; echo; echo 'Press any key to close this window...'; read -n 1"
	
	tell application "Terminal"
		activate
		do script terminalCommand
	end tell
end run
