local wez = require "wezterm"
local utilities = require "bar.utilities"

---@private
---@class bar.system
local M = {}

local last_cpu_update = 0
local stored_cpu = ""
local last_disk_update = 0
local stored_disk = ""

---gets the current cpu usage percentage
---@param throttle integer
---@return string
M.get_cpu_usage = function(throttle)
  if utilities._wait(throttle, last_cpu_update) then
    return stored_cpu
  end

  local success, stdout
  if utilities.is_windows then
    success, stdout = wez.run_child_process { "wmic", "cpu", "get", "loadpercentage", "/value" }
    if success then
      local pct = stdout:match "LoadPercentage=(%d+)"
      stored_cpu = pct and (pct .. "%") or ""
    end
  else
    success, stdout = wez.run_child_process { "ps", "-A", "-o", "%cpu" }
    if success then
      local sum = 0
      for val in stdout:gmatch "[%d.]+" do
        sum = sum + (tonumber(val) or 0)
      end
      local ncpu_ok, ncpu_out = wez.run_child_process { "sysctl", "-n", "hw.ncpu" }
      local ncpu = 1
      if ncpu_ok then
        ncpu = tonumber(ncpu_out:match "%d+") or 1
      end
      local pct = math.floor(sum / ncpu + 0.5)
      stored_cpu = tostring(pct) .. "%"
    end
  end

  last_cpu_update = os.time()
  return stored_cpu
end

---gets the available disk space on the root volume
---@param throttle integer
---@return string
M.get_disk_usage = function(throttle)
  if utilities._wait(throttle, last_disk_update) then
    return stored_disk
  end

  local success, stdout
  if utilities.is_windows then
    success, stdout = wez.run_child_process {
      "powershell",
      "-NoProfile",
      "-Command",
      [[$d=(Get-PSDrive C); $free=[math]::Round($d.Free/1GB,0); Write-Output "$free GB free"]],
    }
    if success then
      stored_disk = utilities._trim(stdout) or ""
    end
  else
    success, stdout = wez.run_child_process { "df", "-k", "/" }
    if success then
      -- columns: filesystem, total, used, available
      local lines = stdout:match "\n(.+)"
      if lines then
        local col = 0
        local avail_kb
        for val in lines:gmatch "%S+" do
          col = col + 1
          if col == 4 then
            avail_kb = tonumber(val)
            break
          end
        end
        if avail_kb then
          local avail_gb = avail_kb / 1024 / 1024
          stored_disk = string.format("%.1f GB free", avail_gb)
        end
      end
    end
  end

  last_disk_update = os.time()
  return stored_disk
end

return M
