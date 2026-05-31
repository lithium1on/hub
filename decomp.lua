getgenv().decompile = function(script)
    local ok, bytecode = pcall(getscriptbytecode, script)
    if not ok or not bytecode then
        return "-- error: failed to get bytecode"
    end

    local ok2, result = pcall(request, {
        Url = "https://medal.upio.dev/decompile",
        Method = "POST",
        Body = base64encode(bytecode),
        Headers = {
            ["Content-Type"] = "text/plain"
        }
    })

    if not ok2 or result.StatusCode ~= 200 then
        return "-- error: " .. tostring(result)
    end

    return string.gsub(result.Body, string.char(0x00CD), " ")
end
