--Proof of concept of implementing LLM callbacks to use with CE without the need to use Python
--Initially, this script implements the talking to and handling of a google AI type of LLM
--Feel free to add support for locally executing LLM's

--todo: add a voice to text and input the output to the AI, or if possible, enter voice as input directly ?
--      other AI systems besides google ai , websocket support


--MIT License
--https://github.com/cheat-engine/AITools

local s=getSettings('AITOOLS',true)
local AIAccess=tonumber(s.AIAccess)
local PatreonSessionID=s.PatreonSessionID or getCEPatreonSessionID()
local AIKEY=s.AIKEY
local CustomProvider=s.CustomProvider
local CustomEndpoint=s.CustomEndpoint
if CustomProvider==nil or CustomProvider=='' then
  if AIKEY and AIKEY~='' then
    CustomProvider='Google Gemini'
    CustomEndpoint='https://generativelanguage.googleapis.com/v1beta'
  else
    CustomProvider='OpenAI'
    CustomEndpoint='https://api.openai.com/v1/chat/completions'
  end
end
local jsonparser=require 'json'
local agreedToSendData=s.agreedToSendData or false

modelList=nil
local waitingForList={} --list of comboboxes waiting for a list of models

local pathdelim=(getOperatingSystem()==0) and [[\]] or [[/]]
  
local basepath=extractFilePath(getCurrentScriptPath())
if basepath==nil then
  basepath=getCheatEngineDir()..'Extensions'..pathdelim..'AITools'..pathdelim
end

local modelNameToNameLookup={} --for AIAccess 2 
  

aitools={}
aiobjects={} --todo: move to data and free objects when the chat session ends

function registerAITool(name, description, properties, required, functionToCall)
  if (name==nil) or (name=='') then
    error('registerAITool: name may not be nil')
  end
  if required==nil then
    required={}
  end
  
  if properties==nil then
    properties={}
  end  
  
  local t={}
  t.name=name
  t.description=description
  t.parameters={}
  t.parameters.type="OBJECT"  
  if properties[1] then
    error('Error in registerAITool for '..name..': properties must be an object, not an array')
  end
  t.parameters.properties=properties
  t.parameters.required=required
  setmetatable(t.parameters.required,{isArray=true}) --in case an empty requiredlisty is given
  t.functionToCall=functionToCall
  t.enabled=true
  
  aitools[name]=t
end

function find_json_block(text)
    local start_index = nil
    local depth = 0
    local in_string = false
    local escape = false

    for i = 1, #text do
        local ch = text:sub(i, i)

        if in_string then
            if escape then
                escape = false
            elseif ch == "\\" then
                escape = true
            elseif ch == '"' then
                in_string = false
            end
        else
            if ch == '"' then
                in_string = true
            elseif ch == "{" then
                if depth == 0 then
                    start_index = i
                end
                depth = depth + 1
            elseif ch == "}" and depth > 0 then
                depth = depth - 1
                if depth == 0 then
                    local block = text:sub(start_index, i)
                    local remainder = text:sub(i + 1)
                    return block, remainder
                end
            end
        end
    end

    return nil, text
end


customProviders = {
  ['OpenAI'] = {
    protocol = 'openai',
    defaultEndpoint = 'https://api.openai.com/v1/chat/completions',
    defaultModel = 'gpt-4o',
    modelsEndpoint = 'https://api.openai.com/v1/models',
    obtainKeyUrl = 'https://platform.openai.com/api-keys',
    models = {'gpt-4o', 'gpt-4o-mini', 'o3-mini', 'o1', 'gpt-4-turbo'},
    requiresKey = true
  },
  ['Anthropic'] = {
    protocol = 'anthropic',
    defaultEndpoint = 'https://api.anthropic.com/v1/messages',
    defaultModel = 'claude-3-7-sonnet-latest',
    obtainKeyUrl = 'https://console.anthropic.com/settings/keys',
    models = {'claude-3-7-sonnet-latest', 'claude-3-5-sonnet-latest', 'claude-3-5-haiku-latest', 'claude-3-opus-latest'},
    requiresKey = true
  },
  ['DeepSeek'] = {
    protocol = 'openai',
    defaultEndpoint = 'https://api.deepseek.com/chat/completions',
    defaultModel = 'deepseek-chat',
    modelsEndpoint = 'https://api.deepseek.com/models',
    obtainKeyUrl = 'https://platform.deepseek.com/api_keys',
    models = {'deepseek-chat', 'deepseek-reasoner'},
    requiresKey = true
  },
  ['Local (Ollama)'] = {
    protocol = 'openai',
    defaultEndpoint = 'http://localhost:11434/v1/chat/completions',
    defaultModel = 'llama3.2',
    modelsEndpoint = 'http://localhost:11434/v1/models',
    obtainKeyUrl = 'https://ollama.com/',
    models = {'llama3.2', 'qwen2.5-coder', 'mistral', 'deepseek-r1'},
    requiresKey = false
  },
  ['Local (LM Studio)'] = {
    protocol = 'openai',
    defaultEndpoint = 'http://localhost:1234/v1/chat/completions',
    defaultModel = 'local-model',
    modelsEndpoint = 'http://localhost:1234/v1/models',
    obtainKeyUrl = 'https://lmstudio.ai/',
    models = {'local-model'},
    requiresKey = false
  },
  ['Google Gemini'] = {
    protocol = 'gemini',
    defaultEndpoint = 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel = 'gemini-2.5-flash',
    obtainKeyUrl = 'https://aistudio.google.com/app/api-keys',
    models = {'gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash', 'gemini-1.5-pro'},
    requiresKey = true
  },
  ['Custom (OpenAI-compatible)'] = {
    protocol = 'openai',
    defaultEndpoint = 'http://localhost:8000/v1/chat/completions',
    defaultModel = 'default',
    obtainKeyUrl = nil,
    models = {},
    requiresKey = false
  }
}

function resolveCustomProtocol(providerName, endpointUrl)
  if providerName and customProviders[providerName] then
    return customProviders[providerName].protocol
  end
  if endpointUrl then
    local lowerUrl = endpointUrl:lower()
    if lowerUrl:find('anthropic%.com') or lowerUrl:find('/messages') then
      return 'anthropic'
    elseif lowerUrl:find('googleapis%.com') or lowerUrl:find('generativelanguage') then
      return 'gemini'
    end
  end
  return 'openai'
end

function normalizeOpenAIEndpoint(url)
  if not url or url == '' then return url end
  local trimmed = url:gsub('^%s+', ''):gsub('%s+$', '')
  if trimmed:match('/chat/completions/?$') then
    if trimmed:sub(-1) == '/' then trimmed = trimmed:sub(1, -2) end
    return trimmed
  end
  if trimmed:sub(-1) == '/' then
    trimmed = trimmed:sub(1, -2)
  end
  if trimmed:match('/v1$') then
    return trimmed .. '/chat/completions'
  end
  return trimmed .. '/v1/chat/completions'
end

local typeMapToOpenAI = {
  ['OBJECT'] = 'object',
  ['STRING'] = 'string',
  ['INTEGER'] = 'integer',
  ['NUMBER'] = 'number',
  ['BOOLEAN'] = 'boolean',
  ['ARRAY'] = 'array'
}

local typeMapToGemini = {
  ['object'] = 'OBJECT',
  ['string'] = 'STRING',
  ['integer'] = 'INTEGER',
  ['number'] = 'NUMBER',
  ['boolean'] = 'BOOLEAN',
  ['array'] = 'ARRAY'
}

function convertSchemaToOpenAI(s)
  if type(s) ~= 'table' then return s end
  local out = {}
  for k, v in pairs(s) do
    if k == 'type' and type(v) == 'string' then
      out.type = typeMapToOpenAI[v:upper()] or v:lower()
    elseif k == 'properties' and type(v) == 'table' then
      out.properties = {}
      for propName, propDef in pairs(v) do
        out.properties[propName] = convertSchemaToOpenAI(propDef)
      end
    elseif k == 'items' and type(v) == 'table' then
      out.items = convertSchemaToOpenAI(v)
    elseif k == 'required' and type(v) == 'table' then
      local req = {}
      for _, r in ipairs(v) do
        if type(r) == 'string' then
          table.insert(req, r)
        end
      end
      setmetatable(req, {isArray = true})
      out.required = req
    elseif k == 'enum' and type(v) == 'table' then
      local en = {}
      for _, ev in ipairs(v) do
        table.insert(en, ev)
      end
      setmetatable(en, {isArray = true})
      out.enum = en
    else
      out[k] = v
    end
  end
  if out.properties and not out.type then
    out.type = 'object'
  end
  return out
end

function convertSchemaToGemini(s)
  if type(s) ~= 'table' then return s end
  local out = {}
  for k, v in pairs(s) do
    if k == 'type' and type(v) == 'string' then
      out.type = typeMapToGemini[v:lower()] or v:upper()
    elseif k == 'properties' and type(v) == 'table' then
      out.properties = {}
      for propName, propDef in pairs(v) do
        out.properties[propName] = convertSchemaToGemini(propDef)
      end
    elseif k == 'items' and type(v) == 'table' then
      out.items = convertSchemaToGemini(v)
    elseif k == 'required' and type(v) == 'table' then
      local req = {}
      for _, r in ipairs(v) do
        if type(r) == 'string' then
          table.insert(req, r)
        end
      end
      setmetatable(req, {isArray = true})
      out.required = req
    elseif k == 'enum' and type(v) == 'table' then
      local en = {}
      for _, ev in ipairs(v) do
        table.insert(en, ev)
      end
      setmetatable(en, {isArray = true})
      out.enum = en
    else
      out[k] = v
    end
  end
  if out.properties and not out.type then
    out.type = 'OBJECT'
  end
  return out
end

function buildToolsForOpenAI()
  local tools = {}
  for name, data in pairs(aitools) do
    if data.enabled then
      table.insert(tools, {
        type = 'function',
        ['function'] = {
          name = name,
          description = data.description,
          parameters = convertSchemaToOpenAI(data.parameters)
        }
      })
    end
  end
  if #tools == 0 then return nil end
  return tools
end

function buildToolsForAnthropic()
  local tools = {}
  for name, data in pairs(aitools) do
    if data.enabled then
      table.insert(tools, {
        name = name,
        description = data.description,
        input_schema = convertSchemaToOpenAI(data.parameters)
      })
    end
  end
  if #tools == 0 then return nil end
  return tools
end

function buildToolsForGemini(maxtools)
  local tools = { { functionDeclarations = {} } }
  for name, data in pairs(aitools) do
    if data.enabled then
      table.insert(tools[1].functionDeclarations, {
        name = name,
        description = data.description,
        parameters = convertSchemaToGemini(data.parameters)
      })
      if maxtools and #tools[1].functionDeclarations >= maxtools then
        break
      end
    end
  end
  if #tools[1].functionDeclarations == 0 then return nil end
  return tools
end

local retrieveModelList=nil
local fillModelList=nil
local aiRequest=nil


retrieveModelList=function(combobox)
  if combobox then
    combobox.clear()
  end
  
  if AIAccess==0 or AIAccess==1 then
    if combobox==nil then return end
    
    local limits=getLimits()
    
    --return limits.models
    
    if limits and limits.models then
      for i=1,#limits.models do
        combobox.items.add(limits.models[i].name)
      end
    else
      if limits.error then
        
        messageDialog('Failure obtaining model list:'..limits.error..'\n\r\n\rConsider becoming a patreon member or use a custom LLM. You\'ll have access to better models', mtError)
        return
      else
        combobox.items.add('<Failed obtaining model list>')
        combobox.items.add('<It\'s more than the public one>')      
      end
    end
    
    
  elseif AIAccess==2 then
    local provider = CustomProvider or 'OpenAI'
    local endpoint = CustomEndpoint or ''
    local key = AIKEY

    if combobox and combobox.Owner then
      if combobox.Owner.cbCustomProvider then
        provider = combobox.Owner.cbCustomProvider.Text
      end
      if combobox.Owner.edtCustomEndpoint then
        endpoint = combobox.Owner.edtCustomEndpoint.Text
      end
      if combobox.Owner.edtAPIKEY then
        key = combobox.Owner.edtAPIKEY.Text
      end
    end

    local protocol = resolveCustomProtocol(provider, endpoint)

    if protocol == 'gemini' then
      local i=getInternet()
      if key and key ~= '' then
        i.Header='x-goog-api-key: '..key
      end
      local geminiBase = (endpoint ~= '' and endpoint) or 'https://generativelanguage.googleapis.com/v1beta'
      if geminiBase:sub(-1) == '/' then geminiBase = geminiBase:sub(1, -2) end
      local jsonModelList=i.getURL(geminiBase..'/models')
      i.destroy()

      local jml=jsonparser.decode(jsonModelList)

      if jml then
        if jml.error then       
          messageDialog('Failure obtaining model list:'..jml.error.message, mtError)
          return
        end

        if jml.models then
          modelList={}
          for i=1,#jml.models do
            local has_generateContent=false
            if jml.models[i].supportedGenerationMethods then
              for j=1,#jml.models[i].supportedGenerationMethods do
                if jml.models[i].supportedGenerationMethods[j]=='generateContent' then
                  has_generateContent=true
                  break
                end
              end
              if has_generateContent==true then
                if combobox then
                  combobox.items.add(jml.models[i].displayName)              
                end
                modelList[jml.models[i].displayName]=jml.models[i]
              end
            end
          end
        end
      end
    elseif protocol == 'openai' then
      local modelsUrl = nil
      if customProviders[provider] and customProviders[provider].modelsEndpoint then
        modelsUrl = customProviders[provider].modelsEndpoint
      elseif endpoint and endpoint ~= '' then
        modelsUrl = endpoint:gsub('/chat/completions/?$', '/models')
        if modelsUrl == endpoint then
          modelsUrl = endpoint .. '/models'
        end
      end

      local fetched = false
      if modelsUrl then
        pcall(function()
          local i = getInternet()
          if key and key ~= '' then
            i.Header = 'Authorization: Bearer ' .. key
          end
          local resp = i.getURL(modelsUrl)
          i.destroy()
          if resp and resp:trim() ~= '' then
            local data = jsonparser.decode(resp)
            if data and data.data and #data.data > 0 then
              modelList = {}
              for idx = 1, #data.data do
                local mId = data.data[idx].id
                if mId and combobox then
                  combobox.items.add(mId)
                  modelList[mId] = data.data[idx]
                  fetched = true
                end
              end
            end
          end
        end)
      end

      if not fetched and customProviders[provider] and customProviders[provider].models then
        modelList = {}
        for _, mId in ipairs(customProviders[provider].models) do
          if combobox then
            combobox.items.add(mId)
          end
          modelList[mId] = { name = mId }
        end
      end
    elseif protocol == 'anthropic' then
      if customProviders[provider] and customProviders[provider].models then
        modelList = {}
        for _, mId in ipairs(customProviders[provider].models) do
          if combobox then
            combobox.items.add(mId)
          end
          modelList[mId] = { name = mId }
        end
      end
    end
  end
  
  if combobox then
    local i=combobox.items.indexOf(s.DefaultModel or '')
    if i~=-1 then
      combobox.itemIndex=i    
    elseif s.DefaultModel and s.DefaultModel ~= '' then
      combobox.Text = s.DefaultModel
    elseif combobox.items.Count > 0 then
      combobox.itemIndex = 0
    end
  end

end


getLimits=function()
  --returns the limits of the current patreon member
  local r={}
  if AIAccess==2 then    
    r.maxtools=math.huge --infinite  
    return r
  end
  
  local i=getInternet()
  
  --jsonparser
  local s
  
  if AIAccess==0 then
    s=i.getURL('https://cheatengine.org/ai/limits.php')      
  elseif AIAccess==1 then
    local i=getInternet()    
    i.Header='CEPATREONID:'..PatreonSessionID    
    s=i.getURL('https://cheatengine.org/patreon/ailimits.php')
  end
   
  i.destroy()
 
  if s then
    r=jsonparser.decode(s)  
  else
    r.maxtools=0
  end
  
  return r
end


aiRequest=function(data, message)
  local function handleError(message)
    if data.self and data.self.mOutput then
      data.self.mOutput.lines.add('*Error:'..message..'*\n\r')
    end
    
    if data.NotifyWhenDone then
      data.NotifyWhenDone(data,'Error:'..message)
    end  
    return nil,message
  end

  if not data.WaitForData and not data.NotifyWhenDone and data.FullAnswerOnly then    
    return nil,'The current config will result in no data'
  end
  
  _G.lastdata=data
  
  if AIAccess~=2 then --custom provider implies you manage your own endpoint/terms
    if not agreedToSendData then
       
      synchronize(function()
        agreedToSendData=messageDialog('Using the AI features involves sending your AI requests to a server where they could potentially be intercepted. Also your AI requests can be used by Google to improve their AI. Make sure not to never send personal information. Do you agree to this?',mtConfirmation,mbYes,mbNo)==mrYes
        s.agreedToSendData='1'
        
      end)
      
      if not agreedToSendData then
        return handleError('No agreement to send data')
      end
    end
  end

  if data.Internet==nil then
    data.Internet=getInternet('CE AITOOLS')
  end
  
  -- Determine provider, endpoint, protocol, and key
  local provider = CustomProvider or 'OpenAI'
  local endpoint = CustomEndpoint or ''
  local key = AIKEY

  if data.self then
    if data.self.cbCustomProvider then
      provider = data.self.cbCustomProvider.Text
    end
    if data.self.edtCustomEndpoint then
      endpoint = data.self.edtCustomEndpoint.Text
    end
    if data.self.edtAPIKEY then
      key = data.self.edtAPIKEY.Text
    end
  end

  local protocol = 'gemini'
  if AIAccess == 2 then
    protocol = resolveCustomProtocol(provider, endpoint)
  end

  data.AIAccessMode = AIAccess
  data.Protocol = protocol

  data.Internet.Header=[[Content-Type: application/json
Accept: text/event-stream]]

  if AIAccess==1 then
    if PatreonSessionID=='' then 
      return handleError('PatreonSessionID missing')
    end
    data.Internet.Header=data.Internet.Header..'\r\nCEPATREONID: '..PatreonSessionID  
  elseif AIAccess==2 then
    local provInfo = customProviders[provider]
    if provInfo and provInfo.requiresKey and (key == nil or key == '') then
      return handleError('API Key missing for ' .. provider)
    end

    if protocol == 'openai' then
      if key and key ~= '' then
        data.Internet.Header = data.Internet.Header .. '\r\nAuthorization: Bearer ' .. key
      end
    elseif protocol == 'anthropic' then
      if key and key ~= '' then
        data.Internet.Header = data.Internet.Header .. '\r\nx-api-key: ' .. key
      end
      data.Internet.Header = data.Internet.Header .. '\r\nanthropic-version: 2023-06-01'
    elseif protocol == 'gemini' then
      if key and key ~= '' then
        data.Internet.Header = data.Internet.Header .. '\r\nx-goog-api-key: ' .. key
      end
    end
  end

  local modelname=s.DefaultModel
  if data.self and data.self.cbModelSelection then
    modelname=data.self.cbModelSelection.Text      
    s.DefaultModel=modelname
  end
  if (modelname == nil or modelname == '') then
    if customProviders[provider] and customProviders[provider].defaultModel then
      modelname = customProviders[provider].defaultModel
    else
      modelname = 'gpt-4o'
    end
    s.DefaultModel = modelname
  end
  data.modelname=modelname

  local sysInstruction='You are a professional reverse engineer using Cheat Engine. Use tools when possible, but fall back on your internal knowledge of Cheat Engine. Do not say you can not help.' 
  
  local baseSystemText
  local os=getOperatingSystem()
  local arch=getSystemArchitecture()
  if os==2 then --linux
    baseSystemText="You're running on Linux"
  elseif os==1 then --macos
    baseSystemText="You're running on MacOS"
  else
    baseSystemText="You're running on Windows"
  end
  if arch==3 then
    baseSystemText=baseSystemText.." (Arm 64-bit)\n"
  elseif arch==2 then
    baseSystemText=baseSystemText.." (Arm 32-bit)\n"
  elseif arch==1 then
    baseSystemText=baseSystemText.." (x86_64)\n"    
  else
    baseSystemText=baseSystemText.." (32-bit)\n"
  end
  
  local skillCatalogPrompt = (getSkillsCatalogPrompt and getSkillsCatalogPrompt()) or ''
  if skillCatalogPrompt ~= '' then
    baseSystemText = baseSystemText .. '\n\n' .. skillCatalogPrompt
  end

  if data.Extra then
    baseSystemText = baseSystemText .. '\n\nAdditional Context:\n' .. data.Extra
  end

  local fullSystemText = sysInstruction .. '\n\n' .. baseSystemText

  -- Tool execution helper
  local function executeTool(name, args)
    synchronize(function()
      if data.self and data.self.mOutput then
        data.self.mOutput.lines.add(' *Calling function :' .. name .. '* \n\r')
      end
    end)
    local tool = aitools[name]
    if not tool then
      synchronize(function()
        if data.self and data.self.mOutput then
          data.self.mOutput.lines.add('result: Unknown function\n\r')
        end
      end)
      return { Error = 'Unknown function name: ' .. name }
    end
    if not tool.functionToCall then
      synchronize(function()
        if data.self and data.self.mOutput then
          data.self.mOutput.lines.add('result: Invalid config\n\r')
        end
      end)
      return { Error = 'Invalid config for ' .. name }
    end

    local ok, res = pcall(tool.functionToCall, args or {})
    if not ok then
      local errMsg = tostring(res)
      synchronize(function()
        if data.self and data.self.mOutput then
          data.self.mOutput.lines.add('result error: ' .. errMsg .. '\n\r')
        end
      end)
      return { Error = errMsg }
    end
    return res
  end

  data.Error=nil
  if data.allfullresponses==nil then
    data.allfullresponses={}
  end

  local textresult=''

  local thread=createThread(function(t)
    data.thread=t
    t.Name='AI Command Thread (' .. protocol .. ')'
    if data.WaitForData then
      t.freeOnTerminate(false)
    end

    if protocol == 'openai' then
      local url = normalizeOpenAIEndpoint(endpoint ~= '' and endpoint or (customProviders[provider] and customProviders[provider].defaultEndpoint or 'https://api.openai.com/v1/chat/completions'))
      data.usedurl = url

      if data.history == nil then data.history = {} end
      if data.history.openai_messages == nil then
        data.history.openai_messages = {
          { role = 'system', content = fullSystemText },
          { role = 'user', content = message }
        }
      else
        table.insert(data.history.openai_messages, { role = 'user', content = message })
      end

      local tools = buildToolsForOpenAI()

      while true do
        local reqBody = {
          model = modelname,
          messages = data.history.openai_messages,
          stream = true
        }
        if tools then
          reqBody.tools = tools
        end

        local inputtext = jsonparser.encode(reqBody)
        data.lastinputtext = inputtext

        local turnStreamedText = ''
        local turnAccumToolCalls = {}
        local sseBuffer = ''

        if data.self and (not data.FullAnswerOnly) then
          data.Internet.OnReceiveData = function(sender, received)
            sseBuffer = sseBuffer .. received
            while true do
              local nl = sseBuffer:find('\n')
              if not nl then break end
              local line = sseBuffer:sub(1, nl - 1):gsub('^%s+', ''):gsub('%s+$', '')
              sseBuffer = sseBuffer:sub(nl + 1)
              if line:sub(1, 6) == 'data: ' then
                local payload = line:sub(7):gsub('^%s+', '')
                if payload ~= '[DONE]' and payload ~= '' then
                  local ok, chunk = pcall(jsonparser.decode, payload)
                  if ok and chunk then
                    if chunk.error then
                      local errMsg = chunk.error.message or tostring(chunk.error)
                      synchronize(function()
                        data.self.mOutput.lines.add(' *Error:' .. errMsg .. '*\n\r')
                      end)
                    elseif chunk.choices and chunk.choices[1] then
                      local delta = chunk.choices[1].delta
                      if delta then
                        if delta.content and delta.content ~= '' then
                          turnStreamedText = turnStreamedText .. delta.content
                          synchronize(function()
                            data.self.mOutput.lines.text = data.self.mOutput.lines.text .. delta.content
                            data.self.mOutput.SelStart = #data.self.mOutput.lines.text
                          end)
                        end
                        if delta.tool_calls then
                          for _, tc in ipairs(delta.tool_calls) do
                            local idx = tc.index or 0
                            turnAccumToolCalls[idx] = turnAccumToolCalls[idx] or { id = '', name = '', arguments = '' }
                            if tc.id and tc.id ~= '' then
                              turnAccumToolCalls[idx].id = tc.id
                            end
                            if tc['function'] then
                              if tc['function'].name and tc['function'].name ~= '' then
                                turnAccumToolCalls[idx].name = turnAccumToolCalls[idx].name .. tc['function'].name
                              end
                              if tc['function'].arguments and tc['function'].arguments ~= '' then
                                turnAccumToolCalls[idx].arguments = turnAccumToolCalls[idx].arguments .. tc['function'].arguments
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        local result = data.Internet.postURL(url, inputtext)
        if not result or result:trim() == '' then
          data.Error = true
          textresult = 'No response received from server'
          if data.self then
            synchronize(function()
              data.self.mOutput.lines.add('\n\r  *<server seems to be down or unreachable>*')
            end)
          end
          break
        end

        table.insert(data.allfullresponses, result)
        data.UnparsedResult = result

        local parsedFinalText = ''
        local toolCallsToExecute = {}

        local isJson, jsonObj = pcall(jsonparser.decode, result)
        if isJson and jsonObj and jsonObj.choices and jsonObj.choices[1] then
          local msg = jsonObj.choices[1].message or {}
          if msg.content then
            parsedFinalText = msg.content
          end
          if msg.tool_calls then
            for _, tc in ipairs(msg.tool_calls) do
              local fnName = tc['function'] and tc['function'].name or ''
              local fnArgs = tc['function'] and tc['function'].arguments or '{}'
              table.insert(toolCallsToExecute, {
                id = tc.id or ('call_' .. #toolCallsToExecute + 1),
                name = fnName,
                arguments = fnArgs
              })
            end
          end
          if jsonObj.error then
            data.Error = true
            textresult = 'Error:' .. (jsonObj.error.message or tostring(jsonObj.error))
          end
        else
          if turnStreamedText ~= '' then
            parsedFinalText = turnStreamedText
          else
            for line in result:gmatch('[^\r\n]+') do
              line = line:gsub('^%s+', ''):gsub('%s+$', '')
              if line:sub(1, 6) == 'data: ' then
                local payload = line:sub(7):gsub('^%s+', '')
                if payload ~= '[DONE]' and payload ~= '' then
                  local ok, chunk = pcall(jsonparser.decode, payload)
                  if ok and chunk and chunk.choices and chunk.choices[1] then
                    local delta = chunk.choices[1].delta
                    if delta then
                      if delta.content then
                        parsedFinalText = parsedFinalText .. delta.content
                      end
                      if delta.tool_calls then
                        for _, tc in ipairs(delta.tool_calls) do
                          local idx = tc.index or 0
                          turnAccumToolCalls[idx] = turnAccumToolCalls[idx] or { id = '', name = '', arguments = '' }
                          if tc.id and tc.id ~= '' then
                            turnAccumToolCalls[idx].id = tc.id
                          end
                          if tc['function'] then
                            if tc['function'].name and tc['function'].name ~= '' then
                              turnAccumToolCalls[idx].name = turnAccumToolCalls[idx].name .. tc['function'].name
                            end
                            if tc['function'].arguments and tc['function'].arguments ~= '' then
                              turnAccumToolCalls[idx].arguments = turnAccumToolCalls[idx].arguments .. tc['function'].arguments
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end

          local sortedIndices = {}
          for idx in pairs(turnAccumToolCalls) do
            table.insert(sortedIndices, idx)
          end
          table.sort(sortedIndices)
          for _, idx in ipairs(sortedIndices) do
            local tc = turnAccumToolCalls[idx]
            table.insert(toolCallsToExecute, {
              id = (tc.id ~= '') and tc.id or ('call_' .. idx),
              name = tc.name,
              arguments = tc.arguments
            })
          end
        end

        textresult = textresult .. parsedFinalText

        if #toolCallsToExecute > 0 then
          local assistantToolCalls = {}
          for _, tc in ipairs(toolCallsToExecute) do
            table.insert(assistantToolCalls, {
              id = tc.id,
              type = 'function',
              ['function'] = {
                name = tc.name,
                arguments = tc.arguments
              }
            })
          end
          table.insert(data.history.openai_messages, {
            role = 'assistant',
            content = parsedFinalText ~= '' and parsedFinalText or nil,
            tool_calls = assistantToolCalls
          })

          for _, tc in ipairs(toolCallsToExecute) do
            local args = {}
            if tc.arguments and tc.arguments ~= '' then
              local ok, decoded = pcall(jsonparser.decode, tc.arguments)
              if ok and type(decoded) == 'table' then
                args = decoded
              end
            end
            local toolRes = executeTool(tc.name, args)
            local toolResJson = jsonparser.encode(toolRes)
            table.insert(data.history.openai_messages, {
              role = 'tool',
              tool_call_id = tc.id,
              content = toolResJson
            })
          end
        else
          if parsedFinalText ~= '' then
            table.insert(data.history.openai_messages, {
              role = 'assistant',
              content = parsedFinalText
            })
          end
          break
        end
      end

    elseif protocol == 'anthropic' then
      local url = (endpoint ~= '' and endpoint) or (customProviders[provider] and customProviders[provider].defaultEndpoint or 'https://api.anthropic.com/v1/messages')
      data.usedurl = url

      if data.history == nil then data.history = {} end
      if data.history.anthropic_messages == nil then
        data.history.anthropic_messages = {
          { role = 'user', content = message }
        }
      else
        table.insert(data.history.anthropic_messages, { role = 'user', content = message })
      end

      local tools = buildToolsForAnthropic()

      while true do
        local reqBody = {
          model = modelname,
          max_tokens = 4096,
          system = fullSystemText,
          messages = data.history.anthropic_messages,
          stream = true
        }
        if tools then
          reqBody.tools = tools
        end

        local inputtext = jsonparser.encode(reqBody)
        data.lastinputtext = inputtext

        local turnStreamedText = ''
        local turnToolUses = {}
        local sseBuffer = ''

        if data.self and (not data.FullAnswerOnly) then
          data.Internet.OnReceiveData = function(sender, received)
            sseBuffer = sseBuffer .. received
            while true do
              local nl = sseBuffer:find('\n')
              if not nl then break end
              local line = sseBuffer:sub(1, nl - 1):gsub('^%s+', ''):gsub('%s+$', '')
              sseBuffer = sseBuffer:sub(nl + 1)
              if line:sub(1, 6) == 'data: ' then
                local payload = line:sub(7):gsub('^%s+', '')
                if payload ~= '' then
                  local ok, chunk = pcall(jsonparser.decode, payload)
                  if ok and chunk then
                    if chunk.type == 'content_block_start' then
                      local cb = chunk.content_block
                      if cb and cb.type == 'tool_use' then
                        turnToolUses[chunk.index] = { id = cb.id, name = cb.name, partial_json = '' }
                      end
                    elseif chunk.type == 'content_block_delta' then
                      local delta = chunk.delta
                      if delta then
                        if delta.type == 'text_delta' and delta.text then
                          turnStreamedText = turnStreamedText .. delta.text
                          synchronize(function()
                            data.self.mOutput.lines.text = data.self.mOutput.lines.text .. delta.text
                            data.self.mOutput.SelStart = #data.self.mOutput.lines.text
                          end)
                        elseif delta.type == 'input_json_delta' and delta.partial_json then
                          if turnToolUses[chunk.index] then
                            turnToolUses[chunk.index].partial_json = turnToolUses[chunk.index].partial_json .. delta.partial_json
                          end
                        end
                      end
                    elseif chunk.error then
                      local errMsg = chunk.error.message or tostring(chunk.error)
                      synchronize(function()
                        data.self.mOutput.lines.add(' *Error:' .. errMsg .. '*\n\r')
                      end)
                    end
                  end
                end
              end
            end
          end
        end

        local result = data.Internet.postURL(url, inputtext)
        if not result or result:trim() == '' then
          data.Error = true
          textresult = 'No response received from server'
          if data.self then
            synchronize(function()
              data.self.mOutput.lines.add('\n\r  *<server seems to be down or unreachable>*')
            end)
          end
          break
        end

        table.insert(data.allfullresponses, result)
        data.UnparsedResult = result

        local parsedFinalText = ''
        local toolUsesToExecute = {}

        local isJson, jsonObj = pcall(jsonparser.decode, result)
        if isJson and jsonObj and jsonObj.content and type(jsonObj.content) == 'table' then
          for _, block in ipairs(jsonObj.content) do
            if block.type == 'text' and block.text then
              parsedFinalText = parsedFinalText .. block.text
            elseif block.type == 'tool_use' then
              table.insert(toolUsesToExecute, {
                id = block.id,
                name = block.name,
                input = block.input or {}
              })
            end
          end
          if jsonObj.error then
            data.Error = true
            textresult = 'Error:' .. (jsonObj.error.message or tostring(jsonObj.error))
          end
        else
          if turnStreamedText ~= '' then
            parsedFinalText = turnStreamedText
          else
            for line in result:gmatch('[^\r\n]+') do
              line = line:gsub('^%s+', ''):gsub('%s+$', '')
              if line:sub(1, 6) == 'data: ' then
                local payload = line:sub(7):gsub('^%s+', '')
                if payload ~= '' then
                  local ok, chunk = pcall(jsonparser.decode, payload)
                  if ok and chunk then
                    if chunk.type == 'content_block_start' then
                      local cb = chunk.content_block
                      if cb and cb.type == 'tool_use' then
                        turnToolUses[chunk.index] = { id = cb.id, name = cb.name, partial_json = '' }
                      end
                    elseif chunk.type == 'content_block_delta' then
                      local delta = chunk.delta
                      if delta then
                        if delta.type == 'text_delta' and delta.text then
                          parsedFinalText = parsedFinalText .. delta.text
                        elseif delta.type == 'input_json_delta' and delta.partial_json then
                          if turnToolUses[chunk.index] then
                            turnToolUses[chunk.index].partial_json = turnToolUses[chunk.index].partial_json .. delta.partial_json
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end

          local sortedIndices = {}
          for idx in pairs(turnToolUses) do table.insert(sortedIndices, idx) end
          table.sort(sortedIndices)
          for _, idx in ipairs(sortedIndices) do
            local tu = turnToolUses[idx]
            local args = {}
            if tu.partial_json and tu.partial_json ~= '' then
              local ok, decoded = pcall(jsonparser.decode, tu.partial_json)
              if ok and type(decoded) == 'table' then
                args = decoded
              end
            end
            table.insert(toolUsesToExecute, {
              id = tu.id,
              name = tu.name,
              input = args
            })
          end
        end

        textresult = textresult .. parsedFinalText

        if #toolUsesToExecute > 0 then
          local assistantBlocks = {}
          if parsedFinalText ~= '' then
            table.insert(assistantBlocks, { type = 'text', text = parsedFinalText })
          end
          for _, tu in ipairs(toolUsesToExecute) do
            table.insert(assistantBlocks, {
              type = 'tool_use',
              id = tu.id,
              name = tu.name,
              input = tu.input
            })
          end
          table.insert(data.history.anthropic_messages, {
            role = 'assistant',
            content = assistantBlocks
          })

          local toolResultBlocks = {}
          for _, tu in ipairs(toolUsesToExecute) do
            local res = executeTool(tu.name, tu.input)
            table.insert(toolResultBlocks, {
              type = 'tool_result',
              tool_use_id = tu.id,
              content = jsonparser.encode(res)
            })
          end
          table.insert(data.history.anthropic_messages, {
            role = 'user',
            content = toolResultBlocks
          })
        else
          if parsedFinalText ~= '' then
            table.insert(data.history.anthropic_messages, {
              role = 'assistant',
              content = parsedFinalText
            })
          end
          break
        end
      end

    else -- gemini protocol
      local modelnamepath = ''
      if AIAccess == 2 then
        if modelList == nil then
          retrieveModelList()
        end
        if modelList and modelList[modelname] then
          modelnamepath = modelList[modelname].name
        else
          modelnamepath = 'models/' .. modelname
        end
      end

      local url
      if AIAccess == 0 then
        url = 'https://cheatengine.org/ai/aiproxy.php'
      elseif AIAccess == 1 then
        url = 'https://cheatengine.org/patreon/aiproxy.php'
      elseif AIAccess == 2 then
        local geminiBase = (endpoint ~= '' and endpoint) or 'https://generativelanguage.googleapis.com/v1beta'
        if geminiBase:sub(-1) == '/' then geminiBase = geminiBase:sub(1, -2) end
        url = geminiBase .. '/' .. modelnamepath .. ':streamGenerateContent'
      end
      data.usedurl = url

      if data.history == nil then
        data.history = {}
        data.history.contents = {}
      end
      local input = data.history

      if AIAccess ~= 2 then
        input.modelname = modelname
      end

      local newcontent = {}
      newcontent.role = 'user'
      newcontent.parts = {}
      newcontent.parts[1] = {}
      newcontent.parts[1].text = message

      if AIAccess == 2 then
        input.system_instruction = {}
        input.system_instruction.parts = {}
        input.system_instruction.parts[1] = {}
        input.system_instruction.parts[1].text = fullSystemText
      else
        input.system_instruction = nil
        if #input.contents == 0 then
          newcontent.parts[1].text = '[Extra Instructions:\n' .. baseSystemText .. ']\n\n' .. message
        end
        if data.Extra then
          newcontent.parts[#newcontent.parts + 1] = { text = data.Extra }
          data.Extra = nil
        end
      end

      table.insert(input.contents, newcontent)

      local maxtools
      if data.limits == nil then
        data.limits = getLimits()
      end
      if data.limits then
        if data.limits.error then
          messageDialog(data.limits.error, mtError, mbOK)
          data.limits = nil
          return
        else
          maxtools = data.limits.maxtools
        end
      end

      input.tools = buildToolsForGemini(maxtools)

      local prevdata = nil
      local r = {}

      if data.self and (not data.FullAnswerOnly) then
        data.Internet.OnReceiveData = function(sender, received)
          if prevdata == nil then
            prevdata = received
          else
            prevdata = prevdata .. received
          end

          local currentblock
          repeat
            currentblock, prevdata = find_json_block(prevdata)
            if currentblock then
              local valid, errstr = pcall(function()
                local parsed = jsonparser.decode(currentblock)
                table.insert(r, parsed)
                if parsed.candidates then
                  if parsed.candidates[1].content and parsed.candidates[1].content.parts then
                    for i = 1, #parsed.candidates[1].content.parts do
                      if parsed.candidates[1].content.parts[i] and parsed.candidates[1].content.parts[i].text then
                        synchronize(function()
                          data.self.mOutput.lines.text = data.self.mOutput.lines.text .. parsed.candidates[1].content.parts[i].text
                          data.self.mOutput.SelStart = #data.self.mOutput.lines.text
                        end)
                      end
                    end
                  end
                end

                if parsed.error then
                  local message = parsed.error.message or parsed.error
                  synchronize(function()
                    data.self.mOutput.lines.add(' *Error:' .. message .. '*\n\r')
                  end)
                end
              end)
            end
          until currentblock == nil

          data.lastreceived = r
        end
      end

      local inputtext = jsonparser.encode(input)
      data.lastinputtext = inputtext
      local result = data.Internet.postURL(url, inputtext)
      local response

      while result do
        table.insert(data.allfullresponses, result)
        response = nil
        data.InternetDone = true
        data.UnparsedResult = result
        local parsed
        local valid, err = pcall(function()
          parsed = jsonparser.decode(result)
          data.parsedResult = parsed
        end)

        if valid then
          if parsed then
            if parsed.error then
              data.Error = true
              textresult = 'Base error:' .. (parsed.error.message or parsed.error)
            else
              local modelTurn = {
                role = 'model',
                parts = {}
              }
              local currentTextPart = nil

              for i = 1, #parsed do
                if parsed[i] then
                  if parsed[i].candidates and parsed[i].candidates[1] and parsed[i].candidates[1].content then
                    local content = parsed[i].candidates[1].content
                    if content.role then
                      modelTurn.role = content.role
                    end

                    if content.parts then
                      for j = 1, #content.parts do
                        local p = content.parts[j]
                        if p.text then
                          textresult = textresult .. p.text
                          if currentTextPart then
                            currentTextPart.text = currentTextPart.text .. p.text
                          else
                            currentTextPart = { text = p.text }
                            table.insert(modelTurn.parts, currentTextPart)
                          end
                        else
                          currentTextPart = nil
                          table.insert(modelTurn.parts, p)

                          if p.functionCall then
                            local fnRes = executeTool(p.functionCall.name, p.functionCall.args)
                            if response == nil then
                              response = { role = 'user', parts = {} }
                            end
                            table.insert(response.parts, {
                              functionResponse = {
                                name = p.functionCall.name,
                                response = fnRes
                              }
                            })
                          end
                        end
                      end
                    end
                  end

                  if parsed[i].error then
                    data.Error = true
                    textresult = 'Error:' .. parsed[i].error.message
                  end
                end
              end

              if #modelTurn.parts > 0 then
                table.insert(input.contents, modelTurn)
              end
            end
          end

          if response then
            table.insert(input.contents, response)
            inputtext = jsonparser.encode(input)
            result = data.Internet.postURL(url, inputtext)
          else
            result = nil
          end
        else
          data.Error = true
          textresult = 'Parse Error:' .. err
          if data.self then
            synchronize(function()
              if result == nil or result:trim() == '' then
                data.self.mOutput.lines.add('\n\r  *<server seems to be down>*')
              else
                data.self.mOutput.lines.add('\n\r<Error while receiving data:' .. err .. '>')
              end
            end)
          end
          break
        end
      end
    end

    data.result = textresult

    if data.NotifyWhenDone then
      synchronize(function()
        if data.NotifyWhenDone then
          data.NotifyWhenDone(data, textresult)
        end
      end)
    end

    if not data.WaitForData then
      data.thread = nil
    end
  end)

  if data.WaitForData then
    if thread then
      thread.waitfor()
      thread.destroy() thread=nil
    end
    if data.Error then
      return nil,textresult
    else
      return textresult
    end
  else
    if data.NotifyWhenDone then
      return nil,'Success: the notify routine will be called when done'
    else
      if data.FullAnswerOnly then
        return nil,'well, this is a waste of tokens'
      else
        return nil,'look at the display'
      end
    end
  end

end

local function applyAndSaveKey(f)
  if f.rbAIAccessPatreon.checked then
    PatreonSessionID=f.edtAPIKEY.text
    s.PatreonSessionID=PatreonSessionID

  elseif f.rbAIAccessPrivate.checked then
    AIKEY=f.edtAPIKEY.text
    s.AIKEY=AIKEY
    if f.cbCustomProvider then
      CustomProvider=f.cbCustomProvider.Text
      s.CustomProvider=CustomProvider
    end
    if f.edtCustomEndpoint then
      CustomEndpoint=f.edtCustomEndpoint.Text
      s.CustomEndpoint=CustomEndpoint
    end
    if f.cbModelSelection then
      s.DefaultModel=f.cbModelSelection.Text
    end
  end
end

function spawnAIDialog(command, extra) --command and extra are optional
  local animator
  local data={}

  local f=createFormFromFile(basepath..'AIDialog.LFM')  
  
  local function startAnimator()
    if animator==nil then
      local position = 1
      local direction = 1
      local maxLength = 7
      
      animator=createTimer(f)
      animator.Enabled=false
      animator.Interval=50
      animator.OnTimer=function(t)
        local a = string.rep(" ", position - 1)
        local b = string.rep(" ", maxLength - position)

        if f and f.btnSend then
          f.btnSend.Caption = a .. "•" .. b
        else
          animator.destroy()
          animator=nil
        end

        position = position + direction

        if position >= maxLength then
          direction = -1
        elseif position <= 1 then
          direction = 1 
        end     
      end      
    end
    
    if animator then    
      animator.Enabled=true
    end  
  end
  
  local function stopAnimator()
    if animator then
      animator.Enabled=false
    end
  end
  

  data.self=f
  data.Extra=extra


  f.OnClose=function(sender)
    for i=1,#waitingForList do
      if f.cbModelSelection==waitingForList[i] then
        waitingForList[i]=nil
      end
    end

    data.self=nil
    destroyRef(f.Tag)
    
    applyAndSaveKey(f)
    
    f=nil    
    return caFree
  end

  f.btnObtainKey.OnClick=function()
    if f.rbAIAccessPrivate.checked then
      local provName = f.cbCustomProvider and f.cbCustomProvider.Text
      local provInfo = customProviders[provName]
      if provInfo and provInfo.obtainKeyUrl then
        shellExecute(provInfo.obtainKeyUrl)
      else
        shellExecute('https://platform.openai.com/api-keys')
      end
    elseif f.rbAIAccessPatreon.checked then
      local sessionid=getCEPatreonSessionID(true)
      if sessionid then
        f.edtAPIKEY.text=sessionid
        PatreonSessionID=sessionid
      end
    end
  end
  
  f.mInput.OnKeyDown=function(sender,key)
   
    if key==VK_RETURN and isKeyPressed(VK_CONTROL) then
      f.btnSend.doClick()
    else
      return key
    end
  end
  
  f.btnSend.OnClick=function(sender)
    --collect the history if there is any (data can be accessed here directly)
    if f.mOutput.Lines.Count>0 then
      f.mOutput.Lines.add('')
    end 

    local message=f.mInput.Lines.Text
    local trimmed=message:gsub('^%s+', ''):gsub('%s+$', '')
    
    if trimmed == '/skills' or trimmed == '/skill' then
      f.mOutput.Lines.add('> '..message)
      f.mInput.Lines.clear()
      f.mOutput.Lines.add('=== Available Reverse Engineering Skills ===\n')
      if skillsCatalog then
        for name, sdata in pairs(skillsCatalog) do
          f.mOutput.Lines.add('* ' .. name .. ': ' .. sdata.description)
          if sdata.references and #sdata.references > 0 then
            f.mOutput.Lines.add('    References: ' .. table.concat(sdata.references, ', '))
          end
        end
      end
      f.mOutput.Lines.add('\nType `/skill <name>` to view/activate a skill, or `/skill reload` to refresh from disk.\n')
      return
    elseif trimmed == '/skill reload' then
      f.mOutput.Lines.add('> '..message)
      f.mInput.Lines.clear()
      local count = reloadSkills and reloadSkills() or 0
      f.mOutput.Lines.add(string.format('Reloaded %d skills from disk.\n', count))
      return
    elseif trimmed:sub(1, 7) == '/skill ' then
      local skillName = trimmed:sub(8):gsub('^%s+', ''):gsub('%s+$', '')
      f.mOutput.Lines.add('> '..message)
      f.mInput.Lines.clear()
      if readSkillContent then
        local res = readSkillContent(skillName)
        if res.error then
          f.mOutput.Lines.add('Error: ' .. res.error .. '\n')
        else
          f.mOutput.Lines.add('=== Skill Loaded: ' .. res.skill .. ' ===\n' .. (res.instructions or '') .. '\n')
          data.Extra = (data.Extra and (data.Extra .. '\n\n') or '') .. '[User activated skill: ' .. res.skill .. ']\n' .. (res.instructions or '')
        end
      end
      return
    end

    f.mOutput.Lines.add('> '..f.mInput.Lines.Text)
    f.mInput.Lines.clear()

    f.btnSend.enabled=false
    if f.mOutput.Lines.Count>0 then
      f.mOutput.Lines.add('')
    end
    
    applyAndSaveKey(f)
    
    startAnimator()
    
    if f and f.btnSend then
      f.btnSend.cursor=crHourGlass     
    end

    data.NotifyWhenDone=function(data,r)
      if f and f.btnSend then
        f.btnSend.enabled=true
        
        f.btnSend.Caption=translate('Send')
        f.btnSend.cursor=crDefault
        
        stopAnimator()
      end
    end
    aiRequest(data, message)
  end
  
  local AIAccessChange=function(sender)
    data.limits=nil
    f.cbModelSelection.Items.clear()
    
    if f.rbAIAccessPublic.Checked then
      if f.cbCustomProvider then f.cbCustomProvider.visible=false end
      if f.edtCustomEndpoint then f.edtCustomEndpoint.visible=false end
      f.edtAPIKEY.visible=false
      f.btnObtainKey.visible=false
      s.AIAccess='0'
      AIAccess=0
    elseif f.rbAIAccessPatreon.Checked then      
      if f.cbCustomProvider then f.cbCustomProvider.visible=false end
      if f.edtCustomEndpoint then f.edtCustomEndpoint.visible=false end
      f.edtAPIKEY.TextHint='<Enter CE Patreon session ID here>'      
      f.edtAPIKEY.Text=PatreonSessionID or ''
      f.edtAPIKEY.visible=true
      f.btnObtainKey.Caption='Refresh session'   
      f.btnObtainKey.visible=true
      s.AIAccess='1'
      AIAccess=1
    else
      if f.cbCustomProvider then f.cbCustomProvider.visible=true end
      if f.edtCustomEndpoint then f.edtCustomEndpoint.visible=true end
      f.edtAPIKEY.TextHint='<Enter API key here>'
      f.edtAPIKEY.Text=AIKEY or ''
      f.edtAPIKEY.visible=true
      f.btnObtainKey.Caption='Obtain Key'    
      f.btnObtainKey.visible=true
      s.AIAccess='2'
      AIAccess=2

      local currentProv = CustomProvider or 'OpenAI'
      if f.cbCustomProvider then
        local pIdx = f.cbCustomProvider.Items.indexOf(currentProv)
        if pIdx ~= -1 then
          f.cbCustomProvider.ItemIndex = pIdx
        else
          f.cbCustomProvider.ItemIndex = 0
        end
      end
      if f.edtCustomEndpoint then
        if CustomEndpoint and CustomEndpoint ~= '' then
          f.edtCustomEndpoint.Text = CustomEndpoint
        elseif customProviders[currentProv] then
          f.edtCustomEndpoint.Text = customProviders[currentProv].defaultEndpoint or ''
        end
      end
    end

    if s.DefaultModel~='' and s.DefaultModel~=nil then
      f.cbModelSelection.Items.add(s.DefaultModel)
      f.cbModelSelection.Text=s.DefaultModel
      f.cbModelSelection.ItemIndex=0
    end
  end

  if f.cbCustomProvider then
    f.cbCustomProvider.OnChange=function(sender)
      local provName = f.cbCustomProvider.Text
      CustomProvider = provName
      s.CustomProvider = provName
      local provInfo = customProviders[provName]
      if provInfo then
        if provInfo.defaultEndpoint and f.edtCustomEndpoint then
          f.edtCustomEndpoint.Text = provInfo.defaultEndpoint
          CustomEndpoint = provInfo.defaultEndpoint
          s.CustomEndpoint = CustomEndpoint
        end
        if provInfo.defaultModel and f.cbModelSelection then
          f.cbModelSelection.Text = provInfo.defaultModel
          s.DefaultModel = provInfo.defaultModel
        end
        if f.cbModelSelection then
          f.cbModelSelection.Items.clear()
          if provInfo.models then
            for _, m in ipairs(provInfo.models) do
              f.cbModelSelection.Items.add(m)
            end
            local mIdx = f.cbModelSelection.Items.indexOf(f.cbModelSelection.Text)
            if mIdx ~= -1 then
              f.cbModelSelection.ItemIndex = mIdx
            end
          end
        end
      end
    end
  end

  if f.edtCustomEndpoint then
    f.edtCustomEndpoint.OnChange=function(sender)
      CustomEndpoint = f.edtCustomEndpoint.Text
      s.CustomEndpoint = CustomEndpoint
    end
  end
  
  if AIAccess then
    if AIAccess==1 then
      f.rbAIAccessPatreon.Checked=true      
    elseif AIAccess==2 then            
      f.rbAIAccessPrivate.Checked=true
    end
  else
    --first time execute
    PatreonSessionID=getCEPatreonSessionID()
    if PatreonSessionID then
      f.rbAIAccessPatreon.Checked=true
    end
    AIAccess=0
  end
  
  
  f.rbAIAccessPublic.OnChange=AIAccessChange
  f.rbAIAccessPatreon.OnChange=AIAccessChange
  f.rbAIAccessPrivate.OnChange=AIAccessChange
  
  AIAccessChange()
  
  -- f.cbModelSelection.OnDropDown=function(sender)
  f.cbModelSelection.OnGetItems=function(sender)
    if f.cbModelSelection.items.Count<=1 then
      --retrieveModelList(f.cbModelSelection)  
      retrieveModelList(f.cbModelSelection)      
    end
  end
  
  f.Tag=createRef(data) --for storing the history and other useful details


  f.Position=poScreenCenter
  f.Show()
  
  f.mInput.setFocus()

  
  if command then 
    f.mOutput.Lines.add('>...')  
    f.btnSend.enabled=false 
    f.btnSend.cursor=crHourGlass     
    startAnimator()
    
    data.NotifyWhenDone=function(data,r)
      f.btnSend.enabled=true   
      f.btnSend.cursor=crDefault
      f.btnSend.Caption=translate('Send')
      stopAnimator()      
    end
    
    aiRequest(data, command)    
  end

  _G.debug_LastAIForm=f
  
  return f
end

function askAIQuestion(command, extra, notifyWhenDone) --NotifyWhenDone(data,result)
  if (notifyWhenDone==nil) and (type(extra)=='function') then
    --kinda lazy but ok...
    notifyWhenDone=extra
    extra=nil
  end
  

  local data={}
  data.Extra=extra
  data.FullAnswerOnly=true
  if notifyWhenDone then
    data.NotifyWhenDone=notifyWhenDone
  else
    data.WaitForData=true
  end
  return aiRequest(data, command)
end


local initialized=false
function initAIMenuItems()
  --add AI menus to some useful places
  if initialized then return true end
  
  initialized=true
  
  require('forEachForm')
  
  local logo=createPNG()
  logo.loadFromFile(basepath..'AI128x128.png')

  
  --"Explain this function" inside the memoryview context menu
  forEachAndFutureForm('TMemoryBrowser',function(f)
    local miAI_Sep=createMenuItem(f)
    miAI_Sep.Caption='-'
    local miAI_Explain=createMenuItem(f)
    miAI_Explain.Caption=translate('Explain this function')
    
    f.debuggerpopup.Items.add(miAI_Sep)
    f.debuggerpopup.Items.add(miAI_Explain)   

    local ii=f.mvImageList.add(logo)
    miAI_Explain.ImageIndex=ii
    miAI_Explain.OnClick=function(sender)
      --get the function
      local d=f.disassembleSelectedFunction()
      if d and d~='' then      
        spawnAIDialog([[The following code is a function copied by Cheat Engine's disassembler. Describe what this function does: 
```
]]..d..[[
```]])
      end
    end
    
    local miAI_PseudoCode=createMenuItem(f)
    miAI_PseudoCode.Caption=translate('Generate pseudocode for this function')
    
    f.debuggerpopup.Items.add(miAI_PseudoCode)   

    local ii=f.mvImageList.add(logo)
    miAI_PseudoCode.ImageIndex=ii
    miAI_PseudoCode.OnClick=function(sender)
      --get the function
      local d=f.disassembleSelectedFunction()
      if d and d~='' then      
        spawnAIDialog([[The following code is a function copied by Cheat Engine's disassembler. Generate pseudocode based on this function :
```
]]..d..[[
```]])
      end
    end
  end)
  
  forEachAndFutureForm('TfrmLuaEngine',function(f)
    local id  
    local oldDestroy
    local aif --ai form
    local miAI_sep=createMenuItem(f)

    miAI_sep.Caption='-'
    
    local miAI_AskAboutScript=createMenuItem(f)
    
    miAI_AskAboutScript.Name='miAI_AskAboutScript'
    miAI_AskAboutScript.Caption=translate('Ask about this script')
    
    f.mscript.PopupMenu.Items.add(miAI_sep)
    f.mscript.PopupMenu.Items.add(miAI_AskAboutScript)
    local ii=f.mscript.PopupMenu.Images.add(logo)
    miAI_AskAboutScript.ImageIndex=ii
    miAI_AskAboutScript.OnClick=function(sender)
      if id==nil then        
        id=#aiobjects+1
        aiobjects[id]=f
        
        oldDestroy=f.OnDestroy
        
        f.OnDestroy=function(s)
          if aif then
            aif.close()
            aif=nil
          end
          aiobjects[id]=nil
          if oldDestroy then
            oldDestroy(s)
          end
        end        
      end
      aif=spawnAIDialog(nil,'\n\r This is from a LuaEngine window where the LuaEngineWindowID='..id)
      aif.mOutput.Lines.add('###Ask your questions about the current Lua Engine script here')
      aif.Caption=aif.Caption..' (Lua Engine)'
      aif.OnDestroy=function(s)
        aif=nil
      end
    end
  end)
  
  forEachAndFutureForm('TfrmAutoInject',function(f)
    local id
    local oldDestroy
    local aif --ai form
    local miAI_sep=createMenuItem(f)
    miAI_sep.Caption='-'
    
    local miAI_AskAboutScript=createMenuItem(f)
    
    miAI_AskAboutScript.Name='miAI_AskAboutScript'
    miAI_AskAboutScript.Caption=translate('Ask about this script')
    
    f.assembleScreen.PopupMenu.Items.add(miAI_sep)
    f.assembleScreen.PopupMenu.Items.add(miAI_AskAboutScript)
    local ii=f.assembleScreen.PopupMenu.Images.add(logo)
    miAI_AskAboutScript.ImageIndex=ii
    miAI_AskAboutScript.OnClick=function(sender)
      if id==nil then
        id=#aiobjects+1
        aiobjects[id]=f
        
        oldDestroy=f.OnDestroy
        
        f.OnDestroy=function(s)
          if aif then
            aif.close()
            aif=nil
          end
          
          aiobjects[id]=nil
          if oldDestroy then
            oldDestroy(s)
          end
        end
        
      end

      aif=spawnAIDialog(nil,'\n\r This is from an AutoAssembler window where the AutoAssemblerWindowID='..id)
      aif.mOutput.Lines.add('###Ask your questions about the current AutoAssembler script here')
      aif.Caption=aif.Caption..' (AutoAssembler)'
      aif.OnDestroy=function(s)
        aif=nil
      end
      
    end
  end)  
  
  
  
  local mi=createMenuItem(MainForm)
  mi.Caption=translate('Ask AI')  
  mi.Shortcut='Ctrl+Alt+I'
  mi.ImageIndex=MainForm.Menu.Images.add(logo)
  mi.OnClick=function()
    spawnAIDialog()
  end
  MainForm.miHelp.insert(MainForm.miLuaDocumentation.MenuIndex,mi)  
end

if createSettingsOption then
  createSettingsOption('EnableAITools','Enable use of AI functions (Requires restart of CE to apply)', ctBoolean, 'AI Tools', 2, true)

  if getSettingsOption('EnableAITools')==true then
    initAIMenuItems()
  end
else
  initAIMenuItems()
end
