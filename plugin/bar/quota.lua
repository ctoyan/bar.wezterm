local wez = require "wezterm"
local utilities = require "bar.utilities"

---@private
---@class bar.quota
local M = {}

local last_update = 0
local cached_data = nil
local consecutive_errors = 0
local cached_token = nil

-- Burn rate tracking
local usage_history = {}
local MAX_HISTORY = 10

local function cred_path()
  return utilities.home .. "/.claude/.credentials.json"
end

local function get_token()
  local f = io.open(cred_path(), "r")
  if not f then
    return nil, nil, "no credentials file"
  end
  local content = f:read "*a"
  f:close()

  local token = content:match '"claudeAiOauth"%s*:%s*{[^}]*"accessToken"%s*:%s*"([^"]+)"'
  if not token then
    return nil, nil, "no accessToken in credentials"
  end

  local expires_at = content:match '"expiresAt"%s*:%s*(%d+)'
  return token, tonumber(expires_at), nil
end

local claude_version = nil
local function get_claude_version()
  if claude_version then
    return claude_version
  end
  local ok, stdout = pcall(function()
    local success, out = wez.run_child_process { "claude", "--version" }
    if success and out then
      return out
    end
    return nil
  end)
  if ok and stdout then
    local ver = stdout:match "(%d+%.%d+%.%d+)"
    if ver then
      claude_version = ver
      return claude_version
    end
  end
  claude_version = "0.0.0"
  return claude_version
end

local function call_usage_api(token)
  local success, stdout = wez.run_child_process {
    "curl",
    "-s",
    "-m", "5",
    "-w", "\n%{http_code}",
    "https://api.anthropic.com/api/oauth/usage",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "-H", "Content-Type: application/json",
    "-H", "User-Agent: claude-code/" .. get_claude_version(),
  }

  if not success or not stdout or stdout == "" then
    return nil, nil, "curl failed"
  end

  local body, http_code = stdout:match "^(.*)\n(%d+)$"
  if not body then
    return stdout, nil, nil
  end

  return body, tonumber(http_code), nil
end

local function current_interval(poll_interval)
  if consecutive_errors == 0 then
    return poll_interval
  end
  return math.min(120 * (2 ^ (consecutive_errors - 1)), 1800)
end

local function record_usage(data)
  if not data or data.error then
    return
  end
  local five = data.five_hour and data.five_hour.utilization or 0
  local seven = data.seven_day and data.seven_day.utilization or 0
  table.insert(usage_history, { time = os.time(), five = five, seven = seven })
  while #usage_history > MAX_HISTORY do
    table.remove(usage_history, 1)
  end
end

local function estimate_cap_secs(field)
  if #usage_history < 2 then
    return nil
  end
  local newest = usage_history[#usage_history]
  local start_idx = #usage_history
  for i = #usage_history - 1, 1, -1 do
    if usage_history[i][field] > newest[field] then
      break
    end
    start_idx = i
  end
  if start_idx >= #usage_history then
    return nil
  end
  local oldest = usage_history[start_idx]
  local dt = newest.time - oldest.time
  if dt <= 0 then
    return nil
  end
  local dp = newest[field] - oldest[field]
  if dp <= 0 then
    return nil
  end
  local remaining = 100 - newest[field]
  if remaining <= 0 then
    return 0
  end
  return remaining / (dp / dt)
end

local function time_until(reset_str)
  if not reset_str then
    return "?"
  end
  local year, month, day, hour, min, sec = reset_str:match "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
  if not year then
    return "?"
  end
  local reset_time = os.time {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  }
  local now_local = os.time()
  local now_utc = os.time(os.date("!*t", now_local))
  local diff = reset_time - now_utc

  if diff <= 0 then
    return "now"
  elseif diff < 3600 then
    return string.format("%dm", math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format("%dh%dm", math.floor(diff / 3600), math.floor((diff % 3600) / 60))
  else
    return string.format("%dd%dh", math.floor(diff / 86400), math.floor((diff % 86400) / 3600))
  end
end

local function format_cap_time(secs)
  if secs <= 0 then
    return "now"
  elseif secs < 60 then
    return "<1m"
  elseif secs < 3600 then
    return string.format("~%dm", math.floor(secs / 60))
  elseif secs < 86400 then
    return string.format("~%dh%dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  else
    return ">1d"
  end
end

local function fetch_usage(poll_interval)
  local now = os.time()
  local interval = current_interval(poll_interval)
  if (now - last_update) < interval then
    return cached_data
  end

  local token, expires_at = get_token()
  if not token then
    last_update = now
    return cached_data
  end

  if cached_token and token ~= cached_token then
    consecutive_errors = 0

  end
  cached_token = token

  local now_ms = math.floor(now * 1000)
  if expires_at and now_ms >= expires_at then
    last_update = now

    return cached_data
  end

  local body, status, curl_err = call_usage_api(token)

  if curl_err or status == 429 or status == 401 or status == 403 then
    last_update = now
    consecutive_errors = consecutive_errors + 1
    return cached_data
  end

  local ok, data = pcall(wez.json_parse, body)
  if not ok or not data or data.error then
    last_update = now
    consecutive_errors = consecutive_errors + 1
    return cached_data
  end

  cached_data = data
  last_update = now
  consecutive_errors = 0
  record_usage(data)
  return data
end

---gets Claude API quota usage as a formatted string
---@param throttle integer
---@return string
M.get_usage = function(throttle)
  local data = fetch_usage(throttle)
  if not data then
    return ""
  end

  local five_pct = data.five_hour and data.five_hour.utilization or 0
  local five_reset = data.five_hour and data.five_hour.resets_at
  local seven_pct = data.seven_day and data.seven_day.utilization or 0
  local seven_reset = data.seven_day and data.seven_day.resets_at
  local five_cap = estimate_cap_secs("five")

  local s = string.format("5h %.0f%% (%s)", five_pct, time_until(five_reset))
  if five_cap then
    s = s .. " cap " .. format_cap_time(five_cap)
  end

  s = s .. string.format(" | 7d %.0f%% (%s)", seven_pct, time_until(seven_reset))

  local seven_cap = estimate_cap_secs("seven")
  if seven_cap then
    s = s .. " cap " .. format_cap_time(seven_cap)
  end

  return s
end

return M
