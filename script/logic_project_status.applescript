-- Run with osascript only when you want to query a running Logic Pro instance.
with timeout of 5 seconds
    if application id "com.apple.logic10" is not running then return "Logic Pro is closed."
    tell application id "com.apple.logic10"
        set documentCount to count documents
        if documentCount is 0 then return "Logic Pro has no open documents."
        return name of front document
    end tell
end timeout
