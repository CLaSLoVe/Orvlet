-- Adapted from apple-calendar-applescript/scripts/calendar-event.applescript.
-- Fixed commands only. Event text arrives as arguments, never as script source.
use framework "Foundation"
use scripting additions

on localDate(isoText)
    if (length of isoText) is not 19 then error "Expected local YYYY-MM-DDTHH:MM:SS"
    set parsedDate to current date
    set day of parsedDate to 1
    set year of parsedDate to (text 1 thru 4 of isoText as integer)
    set month of parsedDate to (text 6 thru 7 of isoText as integer)
    set day of parsedDate to (text 9 thru 10 of isoText as integer)
    set time of parsedDate to ((text 12 thru 13 of isoText as integer) * hours + (text 15 thru 16 of isoText as integer) * minutes + (text 18 thru 19 of isoText as integer))
    return parsedDate
end localDate
on padded(n)
    return text -2 thru -1 of ("0" & n)
end padded
on localISO(d)
    return (year of d as text) & "-" & my padded(month of d as integer) & "-" & my padded(day of d) & "T" & my padded(hours of d) & ":" & my padded(minutes of d) & ":" & my padded(seconds of d)
end localISO
on jsonText(value)
    set bytes to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(missing value)
    if bytes is missing value then error "Cannot encode calendar result"
    return (current application's NSString's alloc()'s initWithData:bytes encoding:(current application's NSUTF8StringEncoding)) as text
end jsonText
on safeText(value)
    if value is missing value then return ""
    return value as text
end safeText
on details(targetCalendar, targetEvent, resultStatus)
    set row to current application's NSMutableDictionary's dictionary()
    tell application id "com.apple.iCal"
        row's setObject:resultStatus forKey:"status"
        row's setObject:(name of targetCalendar) forKey:"calendar"
        row's setObject:(my safeText(summary of targetEvent)) forKey:"title"
        row's setObject:(my localISO(start date of targetEvent)) forKey:"start"
        row's setObject:(my localISO(end date of targetEvent)) forKey:"end"
        row's setObject:(allday event of targetEvent) forKey:"allDay"
        row's setObject:(my safeText(location of targetEvent)) forKey:"location"
        row's setObject:(my safeText(url of targetEvent)) forKey:"url"
        row's setObject:(my safeText(description of targetEvent)) forKey:"notes"
        row's setObject:(uid of targetEvent) forKey:"uid"
    end tell
    return row
end details
on run argv
    if (count of argv) is 0 then error "Use list, find, create, read, or validate"
    set operation to item 1 of argv
    if operation is "validate" then return my localISO(my localDate(item 2 of argv))
    if operation is "list" then
        set rows to current application's NSMutableArray's array()
        tell application id "com.apple.iCal"
            repeat with aCalendar in calendars
                set row to current application's NSMutableDictionary's dictionary()
                row's setObject:(name of aCalendar) forKey:"name"
                row's setObject:(writable of aCalendar) forKey:"writable"
                rows's addObject:row
            end repeat
        end tell
        return my jsonText(rows)
    end if
    if operation is "read" then
        if (count of argv) is not 3 then error "read requires calendar and UID"
        set calendarName to item 2 of argv
        set eventUID to item 3 of argv
        tell application id "com.apple.iCal"
            set targetCalendar to first calendar whose name is calendarName
            set targetEvent to first event of targetCalendar whose uid is eventUID
        end tell
        return my jsonText(my details(targetCalendar, targetEvent, "confirmed"))
    end if
    if operation is "find" then
        if (count of argv) is not 3 then error "find requires calendar and start"
        set calendarName to item 2 of argv
        set eventStart to my localDate(item 3 of argv)
        set rows to current application's NSMutableArray's array()
        tell application id "com.apple.iCal"
            set targetCalendar to first calendar whose name is calendarName
            set found to every event of targetCalendar whose start date is eventStart
            repeat with targetEvent in found
                rows's addObject:(my details(targetCalendar, targetEvent, "exists"))
            end repeat
        end tell
        return my jsonText(rows)
    end if
    if operation is not "create" or (count of argv) is not 9 then error "Invalid calendar command"
    set calendarName to item 2 of argv
    set eventTitle to item 3 of argv
    set eventStart to my localDate(item 4 of argv)
    set eventEnd to my localDate(item 5 of argv)
    if eventEnd is less than or equal to eventStart then error "End must be after start"
    set eventLocation to item 6 of argv
    set eventNotes to item 7 of argv
    set eventURL to item 8 of argv
    set allDayText to item 9 of argv
    if allDayText is not "true" and allDayText is not "false" then error "Invalid all-day value"
    set eventAllDay to allDayText is "true"
    tell application id "com.apple.iCal"
        set targetCalendar to first calendar whose name is calendarName
        if not (writable of targetCalendar) then error "Calendar is not writable"
        set matches to every event of targetCalendar whose summary is eventTitle and start date is eventStart
        if (count of matches) is 0 then
            set targetEvent to make new event at end of events of targetCalendar with properties {summary:eventTitle, start date:eventStart, end date:eventEnd, location:eventLocation, description:eventNotes, url:eventURL, allday event:eventAllDay}
            set resultStatus to "created"
        else
            set targetEvent to item 1 of matches
            set resultStatus to "exists"
        end if
    end tell
    return my jsonText(my details(targetCalendar, targetEvent, resultStatus))
end run
