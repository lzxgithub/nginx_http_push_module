--input:  keys: [], values: [channel_id, msg_time, msg_tag, no_msgid_order, create_channel_ttl, subscriber_channel]
--output: result_code, msg_time, msg_tag, message, content_type,  channel_subscriber_count
-- no_msgid_order: 'FILO' for oldest message, 'FIFO' for most recent
-- create_channel_ttl - make new channel if it's absent, with ttl set to this. 0 to disable.
-- result_code can be: 200 - ok, 404 - not found, 410 - gone, 418 - not yet available
local id, time, tag, subscribe_if_current = ARGV[1], tonumber(ARGV[2]), tonumber(ARGV[3])
local no_msgid_order=ARGV[4]
local create_channel_ttl=tonumber(ARGV[5]) or 0
local subscriber_channel = ARGV[6]
local msg_id
if time and time ~= 0 and tag then
  msg_id=("%s:%s"):format(time, tag)
end

local key={
  next_message= 'channel:msg:%s:'..id, --not finished yet
  message=      'channel:msg:%s:%s', --not done yet
  channel=      'channel:'..id,
  messages=     'channel:messages:'..id,
  pubsub=       'channel:subscribers:'..id
}

local subscribe = function(unsub)
  if subscriber_channel and #subscriber_channel>0 then
    --subscribe to this channel.
    redis.call(unsub and 'SREM' or 'SADD',  key.pubsub, subscriber_channel)
  end
end

local enable_debug=true
local dbg = (function(on)
  if on then return function(...) redis.call('echo', table.concat({...})); end
  else return function(...) return; end end
end)(enable_debug)

dbg(' #######  GET_MESSAGE ######## ')

local oldestmsg=function(list_key, old_fmt)
  local old, oldkey
  local n, del=0,0
  while true do
    n=n+1
    old=redis.call('lindex', list_key, -1)
    if old then
      oldkey=old_fmt:format(old)
      local ex=redis.call('exists', oldkey)
      if ex==1 then
        return oldkey
      else
        redis.call('rpop', list_key)
        del=del+1
      end 
    else
      dbg(list_key, " is empty")
      break
    end
  end
end

local tohash=function(arr)
  if type(arr)~="table" then
    return nil
  end
  local h = {}
  local k=nil
  for i, v in ipairs(arr) do
    if k == nil then
      k=v
    else
      --dbg(k.."="..v)
      h[k]=v; k=nil
    end
  end
  return h
end

if no_msgid_order ~= 'FIFO' then
  no_msgid_order = 'FILO'
end

local channel = tohash(redis.call('HGETALL', key.channel))
local new_channel = false
if next(channel) == nil then
  if create_channel_ttl==0 then
    return {404, nil}
  end
  redis.call('HSET', key.channel, 'time', time)
  redis.call('EXPIRE', key.channel, create_channel_ttl)
  channel = {time=time}
  new_channel = true
end

local subs_count = tonumber(channel.subscribers)

local found_msg_id
if msg_id==nil then
  if new_channel then
    dbg("new channel")
    subscribe()
    return {418, nil}
  else
    dbg("no msg id given, ord="..no_msgid_order)
    
    if no_msgid_order == 'FIFO' then --most recent message
      dbg("get most recent")
      found_msg_id=channel.current_message
    elseif no_msgid_order == 'FILO' then --oldest message
      dbg("get oldest")
      
      found_msg_id=oldestmsg(key.messages, ('channel:msg:%s:'..id))
    end
    if found_msg_id == nil then
      --we await a message
      subscribe()
      return {418, nil}
    else
      msg_id = found_msg_id
      local msg=tohash(redis.call('HGETALL', msg_id))
      subscribe('unsub')
      if not next(msg) then --empty
        return {404, nil}
      else
        dbg(("found msg %i:%i  after %i:%i"):format(msg.time, msg.tag, time, tag))
        return {200, tonumber(msg.time) or "", tonumber(msg.tag) or "", msg.data or "", msg.content_type or "", subs_count}
      end
    end
  end
else

  if msg_id and channel.current_message == msg_id
   or not channel.current_message then
    subscribe()
    return {418, nil}
  end

  key.message=key.message:format(msg_id, id)
  local msg=tohash(redis.call('HGETALL', key.message))

  if next(msg) == nil then -- no such message. it might've expired, or maybe it was never there
    dbg("MESSAGE NOT FOUND")
    --subscribe if necessary
    if subscriber_channel and #subscriber_channel>0 then
      --subscribe to this channel.
      redis.call('SADD',  key.pubsub, subscriber_channel)
    end
    return {404, nil}
  end

  local next_msg, next_msgtime, next_msgtag
  if not msg.next then --this should have been taken care of by the channel.current_message check
    dbg("NEXT MESSAGE KEY NOT PRESENT. ERROR, ERROR!")
    return {404, nil}
  else
    dbg("NEXT MESSAGE KEY PRESENT: " .. msg.next)
    key.next_message=key.next_message:format(msg.next)
    if redis.call('EXISTS', key.next_message)~=0 then
      local ntime, ntag, ndata, ncontenttype=unpack(redis.call('HMGET', key.next_message, 'time', 'tag', 'data', 'content_type'))
      dbg(("found msg2 %i:%i  after %i:%i"):format(ntime, ntag, time, tag))
      return {200, tonumber(ntime) or "", tonumber(ntag) or "", ndata or "", ncontenttype or "", subs_count}
    else
      dbg("NEXT MESSAGE NOT FOUND")
      return {404, nil}
    end
  end
end