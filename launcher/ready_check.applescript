use AppleScript version "2.4"
use scripting additions

on run
	set projectRoot to my resolveProjectRoot()
	set setupScriptPath to projectRoot & "/codebase/scripts/setup_env.sh"
	set testCommand to "test -f " & quoted form of setupScriptPath
	
	try
		set probeResult to do shell script testCommand
	on error
		set missingMessage to "PerfoMace ready-check script was not found at:" & linefeed & setupScriptPath
		set probeResult to display dialog missingMessage buttons {"OK"} default button "OK" with icon stop
		return
	end try
	
	set setupOutput to my runStructuredReadyCheck(projectRoot)
	if setupOutput is "" then
		my runTerminalReadyCheck(projectRoot)
		return
	end if
	
	set parsedResult to my parseSetupOutput(setupOutput)
	if parsedResult is missing value then
		my runTerminalReadyCheck(projectRoot)
		return
	end if
	
	my presentReadyCheck(parsedResult, projectRoot)
end run

on resolveProjectRoot()
	set appBundlePath to POSIX path of (path to me)
	set projectRootCommand to "/usr/bin/python3 -c " & quoted form of "import os, sys; print(os.path.abspath(os.path.join(sys.argv[1], '../../..')))" & " " & quoted form of appBundlePath
	set projectRootResult to ""
	tell current application
		set projectRootResult to do shell script projectRootCommand
	end tell
	return projectRootResult
end resolveProjectRoot

on runStructuredReadyCheck(projectRoot)
	set shellCommand to "cd " & quoted form of (projectRoot & "/codebase") & " && PERFOMACE_SETUP_FORMAT=structured bash ./scripts/setup_env.sh"
	try
		set setupResult to ""
		tell current application
			set setupResult to do shell script shellCommand
		end tell
		return setupResult
	on error errMsg number errNum partial result partialOutput
		if partialOutput is not "" then return partialOutput
		return errMsg
	end try
end runStructuredReadyCheck

on parseSetupOutput(setupOutput)
	set checkRecords to {}
	set overallState to "ready"
	set failureCount to 0
	set warningCount to 0
	set summaryMessage to ""
	
	repeat with currentLine in paragraphs of setupOutput
		set lineText to contents of currentLine
			if lineText starts with "SETUP_CHECK|" then
				set checkParts to my splitText(lineText, "|")
				if (count of checkParts) ≥ 6 then
					set end of checkRecords to {checkID:item 2 of checkParts, checkState:item 3 of checkParts, checkTitle:item 4 of checkParts, checkDetail:item 5 of checkParts, checkAction:item 6 of checkParts}
				end if
			else if lineText starts with "SETUP_SUMMARY|" then
				set summaryParts to my splitText(lineText, "|")
				if (count of summaryParts) ≥ 5 then
				set overallState to item 2 of summaryParts
				set failureCount to item 3 of summaryParts as integer
				set warningCount to item 4 of summaryParts as integer
				set summaryMessage to item 5 of summaryParts
			end if
		end if
	end repeat
	
	if (count of checkRecords) is 0 then return missing value
	return {checks:checkRecords, overallState:overallState, failureCount:failureCount, warningCount:warningCount, summaryMessage:summaryMessage}
end parseSetupOutput

on presentReadyCheck(parsedResult, projectRoot)
	set overallState to overallState of parsedResult
	set checkRecords to checks of parsedResult
	set failureCount to failureCount of parsedResult
	set warningCount to warningCount of parsedResult
	set summaryMessage to summaryMessage of parsedResult
	
	set dialogTitle to "PerfoMace Ready Check"
	set headlineText to my headlineForState(overallState)
	set detailLines to {headlineText, summaryMessage, ""}
	
	set highlightedChecks to {}
	repeat with currentCheck in checkRecords
		set checkState to checkState of currentCheck
		if checkState is "fail" or checkState is "warn" then
			set end of highlightedChecks to currentCheck
		end if
	end repeat
	if (count of highlightedChecks) is 0 then set highlightedChecks to items 1 thru (min of {3, count of checkRecords}) of checkRecords
	
	repeat with currentCheck in highlightedChecks
		set checkTitle to checkTitle of currentCheck
		set checkDetail to checkDetail of currentCheck
		set checkAction to checkAction of currentCheck
		set stateLabel to my labelForCheckState(checkState of currentCheck)
		set end of detailLines to "• " & stateLabel & " — " & checkTitle
		set end of detailLines to "  " & checkDetail
		if checkAction is not "" then set end of detailLines to "  Fix: " & checkAction
		set end of detailLines to ""
	end repeat
	
	if (count of highlightedChecks) < (count of checkRecords) then
		set remainingCount to (count of checkRecords) - (count of highlightedChecks)
		set end of detailLines to "More checks are available in the detailed report."
	end if
	
	set dialogMessage to my joinLines(detailLines)
	set buttonList to {"Show Details", "Run In Terminal", "Close"}
	set defaultButton to "Show Details"
	if overallState is "ready" and warningCount is 0 then
		set buttonList to {"Show Details", "Close"}
		set defaultButton to "Close"
	end if
	
	if overallState is "failed" then
		tell current application to set dialogResult to display dialog dialogMessage with title dialogTitle buttons buttonList default button defaultButton with icon stop
	else if overallState is "warning" then
		tell current application to set dialogResult to display dialog dialogMessage with title dialogTitle buttons buttonList default button defaultButton with icon caution
	else
		tell current application to set dialogResult to display dialog dialogMessage with title dialogTitle buttons buttonList default button defaultButton with icon note
	end if
	
	set pressedButton to button returned of dialogResult
	if pressedButton is "Show Details" then
		my openDetailReport(parsedResult, projectRoot)
	else if pressedButton is "Run In Terminal" then
		my runTerminalReadyCheck(projectRoot)
	end if
end presentReadyCheck

on openDetailReport(parsedResult, projectRoot)
	set reportPath to do shell script "/usr/bin/mktemp /tmp/perfomace_ready_check.XXXXXX.txt"
	set reportText to my buildDetailedReport(parsedResult, projectRoot)
	set writeCommand to "/usr/bin/printf %s " & quoted form of reportText & " > " & quoted form of reportPath
	set openCommand to "/usr/bin/open -a TextEdit " & quoted form of reportPath
	set writeResult to do shell script writeCommand
	set openResult to do shell script openCommand
end openDetailReport

on buildDetailedReport(parsedResult, projectRoot)
	set detailLines to {"PerfoMace Ready Check", "Project Root: " & projectRoot, "Generated: " & (current date as text), ""}
	set end of detailLines to headlineForState(overallState of parsedResult)
	set end of detailLines to summaryMessage of parsedResult
	set end of detailLines to ""
	
	repeat with currentCheck in checks of parsedResult
		set end of detailLines to labelForCheckState(checkState of currentCheck) & " — " & checkTitle of currentCheck
		set end of detailLines to checkDetail of currentCheck
		if (checkAction of currentCheck) is not "" then set end of detailLines to "Fix: " & checkAction of currentCheck
		set end of detailLines to ""
	end repeat
	
	set end of detailLines to "Tip: the launcher now shows the same readiness data in its Setup Readiness panel before a run starts."
	return my joinLines(detailLines)
end buildDetailedReport

on runTerminalReadyCheck(projectRoot)
	set terminalCommand to "cd " & quoted form of projectRoot & " && bash ./PerfoMace_Ready_Check.sh; echo; echo 'Press any key to close this window...'; read -n 1"
	tell application "Terminal"
		activate
		do script terminalCommand
	end tell
end runTerminalReadyCheck

on splitText(sourceText, delimiterText)
	set oldDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delimiterText
	set splitItems to text items of sourceText
	set AppleScript's text item delimiters to oldDelimiters
	return splitItems
end splitText

on joinLines(lineList)
	set oldDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to linefeed
	set joinedText to lineList as text
	set AppleScript's text item delimiters to oldDelimiters
	return joinedText
end joinLines

on headlineForState(overallState)
	if overallState is "failed" then return "Setup needs attention before PerfoMace can run."
	if overallState is "warning" then return "Setup is usable, but there are warnings worth fixing."
	return "Setup looks healthy. PerfoMace is ready to run."
end headlineForState

on labelForCheckState(checkState)
	if checkState is "fail" then return "[Blocked]"
	if checkState is "warn" then return "[Warning]"
	return "[Ready]"
end labelForCheckState
