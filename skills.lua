-- Skills Management for Cheat Engine AITools
-- Implements Progressive Disclosure: Lightweight index in prompt, on-demand full loading via getSkill tool
-- MIT License
-- https://github.com/cheat-engine/AITools

local pathdelim = (getOperatingSystem and getOperatingSystem() == 0) and [[\]] or [[/]]

local basepath = extractFilePath(getCurrentScriptPath() or '')
if basepath == nil or basepath == '' then
  if getCheatEngineDir then
    basepath = getCheatEngineDir() .. 'Extensions' .. pathdelim .. 'AITools' .. pathdelim
  else
    basepath = '.' .. pathdelim
  end
end


skillsCatalog = skillsCatalog or {}
local discoveredSkillDirs = {}

-- Helper: Normalize path
local function normalizePath(p)
  if p == nil then return '' end
  if pathdelim == '/' then
    p = p:gsub('\\', '/')
  else
    p = p:gsub('/', '\\')
  end
  if p:sub(-1) ~= pathdelim then
    p = p .. pathdelim
  end
  return p
end

-- Helper: Safely read entire file
local function readFile(filePath)
  local f = io.open(filePath, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Helper: Parse YAML frontmatter from markdown
local function parseSkillMarkdown(content)
  local meta = {}
  local body = content

  if content:sub(1, 3) == '---' then
    local endPos = content:find('\n---', 4, true)
    if endPos then
      local fmText = content:sub(4, endPos)
      body = content:sub(endPos + 4):gsub('^%s*\n', '')
      
      -- Parse key-value lines
      local currentKey = nil
      local currentLines = {}
      for line in fmText:gmatch("[^\r\n]+") do
        local key, val = line:match("^([%w_%-]+)%s*:%s*(.*)$")
        if key then
          if currentKey then
            meta[currentKey] = table.concat(currentLines, " "):gsub("^%s+", ""):gsub("%s+$", "")
          end
          currentKey = key
          currentLines = {}
          val = val:gsub("^['\"]", ""):gsub("['\"]$", "")
          if val ~= "" and val ~= ">-" and val ~= "|-" and val ~= ">" and val ~= "|" then
            table.insert(currentLines, val)
          end
        elseif currentKey and (line:match("^%s+") or line:match("^\t+")) then
          local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
          trimmed = trimmed:gsub("^['\"]", ""):gsub("['\"]$", "")
          if trimmed ~= "" then
            table.insert(currentLines, trimmed)
          end
        end
      end
      if currentKey then
        meta[currentKey] = table.concat(currentLines, " "):gsub("^%s+", ""):gsub("%s+$", "")
      end
    end
  end

  return meta, body
end

-- Helper: Find candidate skill directories
local function findSkillSearchPaths()
  local paths = {}
  
  -- 1. Extension's own skills directory
  local extSkills = normalizePath(basepath .. 'skills')
  table.insert(paths, extSkills)

  -- 2. Traverse up from basepath looking for .agents/skills
  local cur = basepath
  for _ = 1, 6 do
    local cand = normalizePath(cur .. '.agents' .. pathdelim .. 'skills')
    table.insert(paths, cand)
    
    -- Strip trailing delimiter and move to parent
    local trimmed = cur:gsub('[\\/]+$', '')
    local parent = extractFilePath and extractFilePath(trimmed)
    if parent == nil or parent == '' or parent == cur or parent == trimmed then
      break
    end
    cur = parent
  end

  -- 3. Check Cheat Engine directory
  if getCheatEngineDir then
    local ceSkills = normalizePath(getCheatEngineDir() .. 'skills')
    table.insert(paths, ceSkills)
  end

  return paths
end

-- Discover all skills across known search paths
function loadAvailableSkills()
  skillsCatalog = {}
  local searchPaths = findSkillSearchPaths()
  local scannedFolders = {}

  for _, rootPath in ipairs(searchPaths) do
    local isDir = false
    if dirExists then
      isDir = dirExists(rootPath)
    else
      local test = io.open(rootPath .. 'monoscript' .. pathdelim .. 'SKILL.md', 'r')
      if test then
        test:close()
        isDir = true
      end
    end

    if isDir and not scannedFolders[rootPath] then
      scannedFolders[rootPath] = true

      local subdirs = nil
      if getDirectoryList then
        subdirs = getDirectoryList(rootPath)
      else
        -- Fallback: check known skill folders
        subdirs = {'monoscript', 'pointer-scanning', 'auto-assembler', 'unreal-engine', 'memory-scanning', 'dissect-data-structures'}
      end

      if subdirs then
        for i = 1, #subdirs do
          local dirEntry = subdirs[i]
          local folderName = extractFileName and extractFileName(dirEntry) or dirEntry
          if folderName and folderName ~= '.' and folderName ~= '..' and folderName ~= '' then
            local skillDir = normalizePath(rootPath .. folderName)
            local skillFile = skillDir .. 'SKILL.md'
            
            local hasSkill = false
            if fileExists then
              hasSkill = fileExists(skillFile)
            else
              local f = io.open(skillFile, "r")
              if f then f:close() hasSkill = true end
            end

            if hasSkill then
              local content = readFile(skillFile)
              if content then
                local meta, body = parseSkillMarkdown(content)
                local skillName = meta.name or folderName
                local skillDesc = meta.description or ("Cheat Engine skill: " .. skillName)

                -- Find reference files if present
                local references = {}
                local refDir = skillDir .. 'references'
                local hasRefDir = dirExists and dirExists(refDir)
                if hasRefDir and getFileList then
                  local rfiles = getFileList(refDir)
                  if rfiles then
                    for j = 1, #rfiles do
                      local fname = extractFileName(rfiles[j])
                      if fname and fname ~= '' then
                        table.insert(references, 'references/' .. fname)
                      end
                    end
                  end
                end

                -- Store or update in catalog (first occurrence has priority)
                if not skillsCatalog[skillName] then
                  skillsCatalog[skillName] = {
                    name = skillName,
                    folder = folderName,
                    description = skillDesc,
                    dir = skillDir,
                    skillFile = skillFile,
                    references = references
                  }
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Generates the compact progressive disclosure index for the system prompt
function getSkillsCatalogPrompt()
  if not next(skillsCatalog) then
    loadAvailableSkills()
  end

  if not next(skillsCatalog) then
    return ""
  end

  local lines = {}
  table.insert(lines, "Available specialized reverse engineering skills:")
  for name, data in pairs(skillsCatalog) do
    table.insert(lines, string.format("- %s: %s", name, data.description))
  end
  table.insert(lines, "")
  table.insert(lines, "PROGRESSIVE DISCLOSURE: When a user query requires specialized workflows (e.g. Mono/IL2CPP, pointer scanning, writing Auto Assembler scripts, Unreal Engine, memory scans, or structure dissection), call the `getSkill` tool with the `skillName` to retrieve the complete procedural guide before acting.")
  
  return table.concat(lines, "\n")
end

-- Read a skill or reference document on demand
function readSkillContent(skillName, referenceFile)
  if not next(skillsCatalog) then
    loadAvailableSkills()
  end

  local skill = skillsCatalog[skillName]
  if not skill then
    -- Try case-insensitive lookup
    for name, data in pairs(skillsCatalog) do
      if name:lower() == tostring(skillName):lower() then
        skill = data
        break
      end
    end
  end

  if not skill then
    local available = {}
    for name, _ in pairs(skillsCatalog) do
      table.insert(available, name)
    end
    return {
      error = string.format("Skill '%s' not found.", tostring(skillName)),
      availableSkills = available
    }
  end

  -- If a specific reference file was requested
  if referenceFile and referenceFile ~= "" then
    local refPath = skill.dir .. referenceFile
    if not (fileExists and fileExists(refPath)) then
      refPath = skill.dir .. 'references' .. pathdelim .. referenceFile
    end
    
    local content = readFile(refPath)
    if content then
      return {
        skill = skill.name,
        reference = referenceFile,
        content = content
      }
    else
      return {
        error = string.format("Reference file '%s' not found for skill '%s'.", referenceFile, skill.name),
        availableReferences = skill.references
      }
    end
  end

  -- Return the full SKILL.md body and available companion references
  local content = readFile(skill.skillFile)
  if not content then
    return { error = "Unable to read skill file: " .. skill.skillFile }
  end

  local meta, body = parseSkillMarkdown(content)
  local response = {
    skill = skill.name,
    description = skill.description,
    instructions = body
  }

  if #skill.references > 0 then
    response.availableReferences = skill.references
    response.note = "Detailed reference manuals are available. To read a specific manual, call getSkill with reference='<fileName>'."
  end

  return response
end

-- Reload skills from disk (useful after adding or editing skills)
function reloadSkills()
  loadAvailableSkills()
  local count = 0
  for _ in pairs(skillsCatalog) do count = count + 1 end
  return count
end

-- Register the AI tool
if registerAITool then
  registerAITool(
    'getSkill',
    'Retrieves detailed procedural instructions, workflows, and best practices for a specific Cheat Engine reverse engineering skill (e.g. monoscript, pointer-scanning, auto-assembler, unreal-engine, memory-scanning, dissect-data-structures). Call this when tackling specialized tasks.',
    {
      skillName = {
        type = 'STRING',
        description = 'The name of the skill to load (e.g. "monoscript", "pointer-scanning", "auto-assembler", "unreal-engine", "memory-scanning", "dissect-data-structures")'
      },
      reference = {
        type = 'STRING',
        description = 'Optional: The specific reference document to load from the skill (e.g. "references/api_reference.md")'
      }
    },
    {'skillName'},
    function(args)
      local skillName = args.skillName
      local reference = args.reference
      return readSkillContent(skillName, reference)
    end
  )
end

-- Initial discovery on script load
loadAvailableSkills()
