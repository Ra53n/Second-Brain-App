-- ax.applescript — обход и клики по UI SecondBrain через Accessibility.
-- Запуск: osascript ax.applescript <dump|click> [подпись]

on labelOf(k)
	tell application "System Events"
		set lbl to ""
		try
			set lbl to name of k
		end try
		if lbl is missing value or lbl is "" then
			try
				set lbl to value of k
			end try
		end if
		if lbl is missing value or lbl is "" then
			try
				set lbl to description of k
			end try
		end if
		if lbl is missing value then set lbl to ""
		return lbl as text
	end tell
end labelOf

on walk(el, depth, maxDepth, acc)
	if depth > maxDepth then return acc
	tell application "System Events"
		set kids to {}
		try
			set kids to UI elements of el
		end try
		repeat with k in kids
			set r to ""
			try
				set r to role of k
			end try
			set pad to ""
			repeat depth times
				set pad to pad & "  "
			end repeat
			set end of acc to (pad & r & " | " & my labelOf(k))
			set acc to my walk(k, depth + 1, maxDepth, acc)
		end repeat
	end tell
	return acc
end walk

on clickByLabel(el, target, depth)
	if depth > 12 then return false
	tell application "System Events"
		set kids to {}
		try
			set kids to UI elements of el
		end try
		repeat with k in kids
			if my labelOf(k) is target then
				try
					click k
					return true
				end try
				try
					perform action "AXPress" of k
					return true
				end try
			end if
			if my clickByLabel(k, target, depth + 1) then return true
		end repeat
	end tell
	return false
end clickByLabel

on run argv
	set mode to item 1 of argv
	tell application "SecondBrain" to activate
	delay 0.6
	tell application "System Events" to tell process "SecondBrain"
		if (count of windows) is 0 then error "Окно не открыто: сначала open -a SecondBrain"
		set w to window 1
		if mode is "dump" then
			set acc to my walk(w, 0, 10, {})
			set AppleScript's text item delimiters to linefeed
			return acc as text
		else if mode is "click" then
			set target to item 2 of argv
			if my clickByLabel(w, target, 0) then
				delay 0.8
				return "нажато: " & target
			else
				return "НЕ НАЙДЕНО: " & target
			end if
		end if
	end tell
end run
