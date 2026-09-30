--- spatula.audio_stems - Audio stem separation using AI models
--- @module spatula.audio_stems
---
--- Separates audio tracks into stems (vocals, instrumental, drums, bass, etc.)
--- using the audio-separator Python library as a subprocess.
---
--- Requires Python 3 with audio-separator installed:
---   pip install audio-separator[cpu]   (or [gpu] for NVIDIA)
---
--- Usage:
---   local AudioStems = require("spatula.audio_stems")
---   local result = AudioStems.separate("song.mp3", "output_stems/")
---   if result.stems.vocals then
---       -- Use result.stems.vocals path
---   end

local AudioStems = {}

-- Path to the Python script (relative to the spatula directory)
local SCRIPT_PATH = "tools/stem_separator.py"

-- Available models
AudioStems.MODELS = {
    FAST = "UVR-MDX-NET-Inst_HQ_3",       -- Fast, good quality 2-stem
    KARAOKE = "UVR_MDXNET_KARA_2",        -- Optimized for vocals removal
    QUALITY = "htdemucs",                  -- High quality 4-stem
    FULL = "htdemucs_6s",                  -- 6-stem with guitar/piano
}

-- Status tracking for async operations
AudioStems._jobs = {}

--- Find the stem_separator.py script path
--- @return string|nil Path to script, or nil if not found
local function findScript()
    -- Try relative to the current file
    local info = debug.getinfo(1, "S")
    local thisFile = info.source:match("@?(.*)")
    local thisDir = thisFile:match("(.*/)")

    if thisDir then
        local scriptPath = thisDir .. SCRIPT_PATH
        local f = io.open(scriptPath, "r")
        if f then
            f:close()
            return scriptPath
        end
    end

    -- Try relative to current working directory
    local f = io.open(SCRIPT_PATH, "r")
    if f then
        f:close()
        return SCRIPT_PATH
    end

    -- Try in spatula subdirectory
    local altPath = "spatula/" .. SCRIPT_PATH
    f = io.open(altPath, "r")
    if f then
        f:close()
        return altPath
    end

    return nil
end

--- Decode a JSON string to a Lua table
--- @param str string JSON string
--- @return table|nil Decoded table or nil on error
local JSON = require("spatula.json")
local function jsonDecode(str)
    if not str or str == "" then return nil end
    local ok, value = pcall(JSON.decode, str)
    if ok and type(value) == "table" and value ~= JSON.null then return value end
    -- The helper can emit progress lines before its final JSON response.
    for line in str:gmatch("[^\r\n]+") do
        local parsed, result = pcall(JSON.decode, line)
        if parsed and type(result) == "table" and result ~= JSON.null then value = result; ok = true end
    end
    if ok and type(value) == "table" and value ~= JSON.null then return value end
end

--- Encode a Lua string for shell argument
--- @param str string String to encode
--- @return string Shell-safe string
local function shellEscape(str)
    -- Replace single quotes with escaped version
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

--- Check if stems already exist for an audio file
--- @param inputPath string Path to input audio file
--- @param outputDir string Directory for output stems
--- @return table|nil Cached stems info or nil
function AudioStems.checkCached(inputPath, outputDir)
    local scriptPath = findScript()
    if not scriptPath then
        return nil
    end

    local cmd = string.format(
        "python3 %s %s %s --check-only 2>&1",
        shellEscape(scriptPath),
        shellEscape(inputPath),
        shellEscape(outputDir)
    )

    local handle = io.popen(cmd)
    if not handle then return nil end

    local output = handle:read("*a")
    handle:close()

    return jsonDecode(output)
end

--- Separate an audio file into stems (blocking)
--- @param inputPath string Path to input audio file
--- @param outputDir string Directory for output stems
--- @param model string|nil Model to use (default: FAST)
--- @param force boolean|nil Force re-separation even if cached
--- @return table Result with stems paths or error
function AudioStems.separate(inputPath, outputDir, model, force)
    local scriptPath = findScript()
    if not scriptPath then
        return {error = "stem_separator.py not found"}
    end

    model = model or AudioStems.MODELS.FAST

    local forceFlag = force and " --force" or ""
    local cmd = string.format(
        "python3 %s %s %s --model %s%s 2>&1",
        shellEscape(scriptPath),
        shellEscape(inputPath),
        shellEscape(outputDir),
        shellEscape(model),
        forceFlag
    )

    local handle = io.popen(cmd)
    if not handle then
        return {error = "Failed to execute Python script"}
    end

    local output = handle:read("*a")
    local success, _, code = handle:close()

    local result = jsonDecode(output)
    if not result then
        return {error = "Failed to parse output: " .. (output or "(empty)")}
    end

    return result
end

--- Start async stem separation (non-blocking)
--- @param inputPath string Path to input audio file
--- @param outputDir string Directory for output stems
--- @param model string|nil Model to use (default: FAST)
--- @return string Job ID for tracking
function AudioStems.separateAsync(inputPath, outputDir, model)
    local scriptPath = findScript()
    if not scriptPath then
        local jobId = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
        AudioStems._jobs[jobId] = {
            status = "error",
            error = "stem_separator.py not found"
        }
        return jobId
    end

    model = model or AudioStems.MODELS.FAST

    -- Generate a unique job ID
    local jobId = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))

    -- Create a temporary file for output
    local tempFile = os.tmpname()

    local cmd = string.format(
        "python3 %s %s %s --model %s > %s 2>&1 &",
        shellEscape(scriptPath),
        shellEscape(inputPath),
        shellEscape(outputDir),
        shellEscape(model),
        shellEscape(tempFile)
    )

    -- Start the process in background
    os.execute(cmd)

    -- Track the job
    AudioStems._jobs[jobId] = {
        status = "running",
        inputPath = inputPath,
        outputDir = outputDir,
        model = model,
        tempFile = tempFile,
        startTime = os.time()
    }

    return jobId
end

--- Check status of async separation job
--- @param jobId string Job ID from separateAsync
--- @return table Job status with status field ("running", "complete", "error")
function AudioStems.checkJob(jobId)
    local job = AudioStems._jobs[jobId]
    if not job then
        return {status = "unknown", error = "Job not found"}
    end

    if job.status ~= "running" then
        return job
    end

    -- Check if the temp file has content (process completed)
    local f = io.open(job.tempFile, "r")
    if f then
        local content = f:read("*a")
        f:close()

        if content and content ~= "" then
            -- Process completed
            local result = jsonDecode(content)
            if result then
                if result.error then
                    job.status = "error"
                    job.error = result.error
                else
                    job.status = "complete"
                    job.stems = result.stems
                    job.cached = result.cached
                end
            else
                job.status = "error"
                job.error = "Failed to parse output"
            end

            -- Clean up temp file
            os.remove(job.tempFile)
        end
    end

    return job
end

--- Cancel an async job (if possible)
--- @param jobId string Job ID
function AudioStems.cancelJob(jobId)
    local job = AudioStems._jobs[jobId]
    if job and job.tempFile then
        os.remove(job.tempFile)
    end
    AudioStems._jobs[jobId] = nil
end

--- Get default output directory for an audio file
--- @param inputPath string Path to input audio file
--- @return string Output directory path
function AudioStems.defaultOutputDir(inputPath)
    -- Remove extension and add _stems suffix
    local base = inputPath:match("(.+)%.[^.]+$") or inputPath
    return base .. "_stems"
end

--- Check if Python and audio-separator are available
--- @return boolean, string Available and version/error message
function AudioStems.checkDependencies()
    local handle = io.popen("python3 -c \"from audio_separator.separator import Separator; print('OK')\" 2>&1")
    if not handle then
        return false, "Python3 not found"
    end

    local output = handle:read("*a")
    handle:close()

    if output:match("OK") then
        return true, "audio-separator available"
    elseif output:match("ModuleNotFoundError") or output:match("No module named") then
        return false, "audio-separator not installed. Run: pip install audio-separator[cpu]"
    else
        return false, "Python error: " .. output
    end
end

return AudioStems
