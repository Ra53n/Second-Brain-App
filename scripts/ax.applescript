-- ax.applescript — обход и управление UI SecondBrain через Accessibility (задачи 46, 49).
--
-- Запускается через scripts/ui.sh (там таймаут и preflight); напрямую — только для отладки.
--
-- Режимы:
--   list          — только интерактивные элементы с подписями (компактно)
--   check <текст> — есть ли на экране элемент, чья подпись содержит текст: PASS/FAIL
--   click <текст> — нажать такой элемент (click, при неудаче AXPress)
--   dump          — всё дерево окна с отступами (дорого, только для разбора)
--   window        — заголовок окна и число элементов верхнего уровня
--
-- Инварианты (проверено на живом приложении):
--  - без activate приложение в фоне не отдаёт window 1 (ошибка -1719);
--  - `entire contents of window 1` возвращает пусто — нужен ручной обход;
--  - подпись лежит то в name/value (AXStaticText), то в description (кнопки тулбара).

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

-- Полное дерево с отступами.
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

-- Только интерактивное с непустой подписью.
on collectInteractive(el, depth, acc)
	if depth > 12 then return acc
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
			if r is in {"AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXTextField"} then
				set lbl to my labelOf(k)
				if lbl is not "" and lbl does not end with "button" then
					set end of acc to (r & " | " & lbl)
				end if
			end if
			set acc to my collectInteractive(k, depth + 1, acc)
		end repeat
	end tell
	return acc
end collectInteractive

-- Поиск с одной повторной попыткой: первый AX-запрос сразу после activate часто
-- приходит в момент перестроения окна и не видит элементов (ложный FAIL).
on findRetrying(w, target, deepFirst)
	set found to my findByLabel(w, target, 0, deepFirst)
	if found is missing value then
		delay 0.7
		set found to my findByLabel(w, target, 0, deepFirst)
	end if
	return found
end findRetrying

-- Поиск по подстроке подписи: возвращает элемент или missing value.
--
-- Скорость: подписи детей запрашиваются ПАКЕТНО (три Apple Event на контейнер
-- вместо трёх на каждый элемент). На разделе с сотнями строк разница —
-- десятки секунд против долей секунды.
on findByLabel(el, target, depth, deepFirst)
	if depth > 9 then return missing value
	tell application "System Events"
		set kids to {}
		try
			set kids to UI elements of el
		end try
		if kids is {} then return missing value

		set nms to {}
		try
			set nms to name of every UI element of el
		end try
		set vls to {}
		try
			set vls to value of every UI element of el
		end try
		set dsc to {}
		try
			set dsc to description of every UI element of el
		end try

		-- Сначала вглубь: нужен САМЫЙ КОНКРЕТНЫЙ элемент. Контейнер (строка списка,
		-- ячейка) часто отдаёт ту же подпись, что и текст внутри, но клик по строке
		-- SwiftUI-список не выделяет — а клик по тексту внутри работает.
		if deepFirst then
			repeat with k in kids
				set found to my findByLabel(k, target, depth + 1, true)
				if found is not missing value then return found
			end repeat
		end if

		set n to count of kids
		repeat with i from 1 to n
			set lbl to ""
			try
				if (count of nms) ≥ i and item i of nms is not missing value then set lbl to (item i of nms) as text
			end try
			if lbl is "" then
				try
					if (count of vls) ≥ i and item i of vls is not missing value then set lbl to (item i of vls) as text
				end try
			end if
			if lbl is "" then
				try
					if (count of dsc) ≥ i and item i of dsc is not missing value then set lbl to (item i of dsc) as text
				end try
			end if
			if lbl contains target then return item i of kids
		end repeat

		-- Обход «сверху вниз» (check): подпись почти всегда на верхних уровнях,
		-- поэтому сначала уровень, потом вглубь — это в разы дешевле.
		if not deepFirst then
			repeat with k in kids
				set found to my findByLabel(k, target, depth + 1, false)
				if found is not missing value then return found
			end repeat
		end if
	end tell
	return missing value
end findByLabel

on run argv
	set mode to item 1 of argv
	tell application "SecondBrain" to activate
	-- Окно появляется в Accessibility НЕ мгновенно после activate: фиксированная
	-- задержка давала ложное «окно не открыто» и ретраи агента. Опрашиваем до 5 с.
	set w to missing value
	repeat 20 times
		tell application "System Events" to tell process "SecondBrain"
			if (count of windows) > 0 then
				set w to window 1
				exit repeat
			end if
		end tell
		delay 0.25
	end repeat
	if w is missing value then error "ОКНО НЕ ОТКРЫТО: open -a SecondBrain"
	-- Окно уже в AX, но ещё не key: клик, отправленный в этот момент, принимается
	-- без ошибки и молча игнорируется SwiftUI. Даём окну устояться.
	delay 0.4

	tell application "System Events" to tell process "SecondBrain"

		if mode is "window" then
			return (name of w) & " | элементов верхнего уровня: " & (count of UI elements of w)

		else if mode is "list" then
			set acc to my collectInteractive(w, 0, {})
			set AppleScript's text item delimiters to linefeed
			return acc as text

		else if mode is "dump" then
			set acc to my walk(w, 0, 10, {})
			set AppleScript's text item delimiters to linefeed
			return acc as text

		else if mode is "check" then
			set target to item 2 of argv
			-- Ищем во ВСЕХ окнах процесса: окно настроек (Cmd+,) — отдельное,
			-- и «window 1» не обязательно то, что видит пользователь: окна
			-- накапливаются при повторных open -a.
			-- check ищет «сверху вниз»: подпись обычно на верхних уровнях,
			-- полный обход вглубь стоил бы секунды на каждом окне.
			if my findRetrying(w, target, false) is not missing value then return "PASS  " & target
			repeat with ww in windows
				if my findByLabel(ww, target, 0, false) is not missing value then
					return "PASS  " & target & " (окно: " & (name of ww) & ")"
				end if
			end repeat
			return "FAIL  " & target & " — не найдено ни в одном окне"

		else if mode is "click" then
			set target to item 2 of argv
			set el to my findRetrying(w, target, true)
			if el is missing value then return "FAIL  клик: " & target & " — не найдено"
			try
				click el
				delay 0.6
				return "OK    клик: " & target
			end try
			try
				perform action "AXPress" of el
				delay 0.6
				return "OK    клик (AXPress): " & target
			end try
			return "FAIL  клик: " & target & " — элемент не нажимается"
		end if
	end tell
end run
