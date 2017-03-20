#!/usr/bin/env bash


lua_kwrds="assert|ipairs|math|table|require|pairs|string|setmetatable|bit|debug|arg"
lua_kwrds="$lua_kwrds|tostring|tonumber|type|os|io|pcall|print|LUA_PATH|package"
quik_kwrds="getParamEx|getQuoteLevel2|sendTransaction|getNumberOf|getItem|OnInit"
quik_kwrds="$quik_kwrds|OnAllTrade|OnQuote|message|sleep|main|Subscribe_Level_II_Quotes"
quik_kwrds="$quik_kwrds|OnTransReply|OnTrade|OnDisconnected"

processFile() {
    echo analysis of $1
    luac -p -l $1 | grep -P 'ETTABUP.*_ENV' | grep -vP "\b($lua_kwrds)\b" | grep -vP "\b($quik_kwrds)\b"
}

for f in "$@"
do
    processFile "$f"
done
