--Proof of concept of implementing LLM callbacks to use with CE
--Initially, this script implements the talking to and handling of a google AI type of LLM
--Feel free to add support for locally executing LLM's


--MIT License
--https://github.com/cheat-engine/AITools

local s=getSettings('AITOOLS',true)
local AIAccess=tonumber(s.AIAccess)
local PatreonSessionID=s.PatreonSessionID or getCEPatreonSessionID()
local AIKEY=s.AIKEY
local defaultmodel=s.DefaultModel or 'models/gemini-2.5-flash'
local jsonparser=require 'json'
local agreedToSendData=s.agreedToSendData or false

local modelList=nil
local modelListFetcher=nil

local waitingForList={} --list of comboboxes waiting for a list of models

local pathdelim=(getOperatingSystem()==0) and [[\]] or [[/]]
  
local basepath=extractFilePath(getCurrentScriptPath())
if basepath==nil then
  basepath=getCheatEngineDir()..'Extensions'..pathdelim..'AITools'..pathdelim
end
  

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


local retrieveModelList=nil
local fillModelList=nil
local aiRequest=nil


retrieveModelList=function()
  if modelList==nil and modelListFetcher==nil then
    if AIKEY==nil or AIKEY=='' then return end
    
    modelListFetcher=createThread(function(t)
      t.Name='modelListFetcher'
      t.FreeOnTerminate(false)      

      local i=getInternet()
      i.Header='x-goog-api-key: '..AIKEY
      local jsonModelList=i.getURL('https://generativelanguage.googleapis.com/v1beta/models')
      i.destroy()

      local jml=jsonparser.decode(jsonModelList)

      if jml then
        if jml.error then

          synchronize(function()
            
            messageDialog('Failure obtaining model list:'..jml.error.message, mtError)
          end)
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
               -- print(jml.models[i].name)
                table.insert(modelList, jml.models[i])
              end
            end
          end
        end

        if waitingForList and (#waitingForList>0) then

          synchronize(function()
            for i=1,#waitingForList do
              fillModelList(waitingForList[i])
              waitingForList[i].OnGetItems=nil
            end
          end)
        end

        waitingForList={}
      end

    end)
  end
end

fillModelList=function(combobox)

  combobox.items.clear()
  if modelList==nil then
    table.insert(waitingForList, combobox)

    if modelListFetcher==nil then
      if AIKEY then
        combobox.items.add('retrieving list right now')
        retrieveModelList()
      else
        combobox.items.add('Please fill in an API key first')
      end
    else
      combobox.items.add('Please wait for the list to be obtained')
    end

  else
    combobox.items.clear()
    local newindex=-1
    for i=1,#modelList do
      combobox.items.add(modelList[i].displayName)
      if modelList[i].name==defaultmodel then
        newindex=i-1
      end
    end

    combobox.itemIndex=newindex
  end
end


aiRequest=function(data, message)
  local function handleError(message)
    data.self.mOutput.lines.add('Error:'..message)
    
    if data.NotifyWhenDone then
      data.NotifyWhenDone(data,'Error:'..message)
    end  
    return nil,message
  end

  if not data.WaitForData and not data.NotifyWhenDone and data.FullAnswerOnly then    
    return nil,'The current config will result in no data'
  end
  
  _G.lastdata=data
  
  if AIAccess~=2 then --having an AI key implies you accepted their terms
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
  
  
 data.Internet.Header=[[Content-Type: application/json
Accept: text/event-stream]]

 
  if AIAccess==1 then
    if PatreonSessionID=='' then 
      return handleError('PatreonSessionID missing')
    end
    data.Internet.Header=data.Internet.Header..[[
    
CEPATREONID: ]]..PatreonSessionID  
  elseif AIAccess==2 then
    if AIKEY==nil or AIKEY=='' then
      return handleError('AIKEY missing')
    end
    data.Internet.Header=data.Internet.Header..[[
    
x-goog-api-key: ]]..AIKEY
  end


  

  local prevdata=nil
  local r={}
  local allprevdata={}


  data.Error=nil

  if data.self and (not data.FullAnswerOnly) then
    data.Internet.OnReceiveData=function(sender, received)
    
      --print("ondata: "..received)
      --if inMainThread() then
      --  print("in main thread")
      --end      

      if prevdata==nil then
        prevdata=received
      else
        prevdata=prevdata..received
      end

      table.insert(allprevdata, prevdata)

      local currentblock
      repeat
        currentblock, prevdata=find_json_block(prevdata)
        if currentblock then
          local valid,errstr=pcall(function()
            local parsed=jsonparser.decode(currentblock)

            table.insert(r, parsed)
            if parsed.candidates then
              if parsed.candidates[1].content and parsed.candidates[1].content.parts then
                for i=1,#parsed.candidates[1].content.parts do

                  if parsed.candidates[1].content.parts[i] and parsed.candidates[1].content.parts[i].text then
                    synchronize(function()  
                      data.self.mOutput.lines.text=data.self.mOutput.lines.text .. parsed.candidates[1].content.parts[i].text
                      data.self.mOutput.SelStart=#data.self.mOutput.lines.text                      
                    end)
                  end
                end
              end
            end

            if parsed.error then
              local message=nil
              if parsed.error.message then
                message=parsed.error.message
              else
                message=parsed.error
              end
              synchronize(function() 
                data.self.mOutput.lines.add("Error:"..message)
              end)
            end

          end)

          --[[
          if not valid then
            print('Parser error:'..errstr)
            print("----currentblock:---")
            print(currentblock)
            print("----")
            print("----prevdata:---")
            print(prevdata)
            print("----")
                   
          end
          --]]  
        end
      until currentblock==nil

      data.lastreceived=r
      data.allprevdata=allprevdata
    end
  end



  local modelname=defaultmodel
  
  data.AIAccessMode=AIAccess

  if AIAccess==2 and data.self then
    local mlindex=data.self.cbModelSelection.ItemIndex+1
    if mlindex>0 and modelList and #modelList>=mlindex then
      modelname=modelList[mlindex].name      
      s.DefaultModel=modelname
    else
      modelname='models/gemini-2.5-flash'
    end
  end
  
  data.modelname=modelname
  
  
  local input
  if data.history then
    input=data.history
  else
    input={}
    input.contents={}
  end

  local newcontent={}
  newcontent.role='user'  
  newcontent.parts={}  
  newcontent.parts[1]={}
  newcontent.parts[1].text=message  
  table.insert(input.contents,newcontent)
 
  if AIAccess==2 then    
    input.system_instruction={}
    input.system_instruction.parts={}
    input.system_instruction.parts[1]={}
    input.system_instruction.parts[1].text='You are currently being used by the Cheat Engine application'
  end

  if data.Extra then
    if AIAccess==2 then      
      input.system_instruction={}
      input.system_instruction.parts={}
      input.system_instruction.parts[1]={}
      input.system_instruction.parts[1].text=data.Extra
    else
      input.contents.parts[2]={}
      input.contents.parts[2].text=data.Extra      
    end
  end


  --load tools (public max: 2, patreon max: basic 4 , discord: 8; discord+: 12; aibasic: 16; ai: 32 ai plus: 64 , private: unlimited)
  
 
  input.tools={}
  input.tools[1]={}  
  input.tools[1].functionDeclarations={}
  
  for name,data in pairs(aitools) do
    if data.enabled then
      local e={}
      e.name=name
      e.description=data.description
      e.parameters=data.parameters
      --not functionToCall and not Enabled
      table.insert(input.tools[1].functionDeclarations,e)
    end  
  end
  
  if #input.tools[1].functionDeclarations==0 then
    input.tools=nil
  end
  

  data.history=input

  
  local inputtext=jsonparser.encode(input)
  local result
  


  local thread=createThread(function(t)
    data.thread=t
    t.Name='GenerateContent AI command'
    if data.WaitForData then
      t.freeOnTerminate(false)
    end

    local url
    if AIAccess==0 then
      url='https://cheatengine.org/ai/aiproxy.php'
    elseif AIAccess==1 then
      url='https://cheatengine.org/patreon/aiproxy.php'
    elseif AIAccess==2 then
      url='https://generativelanguage.googleapis.com/v1beta/'..modelname..':streamGenerateContent'
    end
    
    data.usedurl=url
    data.lastinputtext=inputtext
    

    result=data.Internet.postURL(url, inputtext)
    local response
    local textresult=''
    
    while result do
      response=nil
      
      data.InternetDone=true
      data.UnparsedResult=result
      local parsed
      local valid,err=pcall(function()
        parsed=jsonparser.decode(result)
        data.parsedResult=parsed
      end)
      
      if valid then
       
        if parsed then
          if parsed.error then
            data.Error=true
            textresult='Base error:'..parsed.error
          else
            for i=1,#parsed do
              if parsed[i] then
                if parsed[i].candidates then
                  if parsed[i].candidates[1] then
                    if parsed[i].candidates[1].content then
                      local newcontent={}  
                      table.insert(input.contents,newcontent)                      
                      newcontent.role=parsed[i].candidates[1].content.role
                     
                      if parsed[i].candidates[1].content.parts then    
                        newcontent.parts={}
                        local parts=parsed[i].candidates[1].content.parts

                        
                        for j=1,#parts do
                          newcontent.parts[j]={}
                          newcontent.parts[j].text=parts[j].text
                          newcontent.parts[j].functionCall=parts[j].functionCall
                          
                          if parts[j].text then
                            textresult=textresult..parts[j].text
                          end
                          
                          if parts[j].functionCall then
                            --parse the args
                            synchronize(function() 
                              if data.self and data.self.mOutput then
                                data.self.mOutput.lines.add('Calling function :'..parts[j].functionCall.name)
                              end
                            end)  
                            
                            if response==nil then
                              response={} --add it if needed
                              response.role='user'
                              response.parts={}
                            end
                            
                            local tool=aitools[parts[j].functionCall.name]
                            
                            local r={}
                            r.functionResponse={}
                            r.functionResponse.name=parts[j].functionCall.name
                            
                            if tool then
                              local f=tool.functionToCall
                              if f then
                                r.functionResponse.response=tool.functionToCall(parts[j].functionCall.args)                                                       
                              else
                                r.functionResponse.response={Error='Invalid config for '..parts[j].functionCall.name}
                                synchronize(function() 
                                  data.self.mOutput.lines.add('result: Invalid config')                            
                                end)                                    
                              end
                            else
                              r.functionResponse.response={Error='Unknown function name'}
                              synchronize(function() 
                                data.self.mOutput.lines.add('result: Unknown function')                            
                              end)                              
                            end
          
  

                            
                            table.insert(response.parts,r)
                          end
                        end                        
                      end
                     
                    end
                  end
                end
                
                if parsed[i].error then
                  data.Error=true
                  textresult='Error:'..parsed[i].error.message
                end                
              end
            end
          end
        end
        
        if response then
          --there's a response to give
          table.insert(input.contents, response)
          inputtext=jsonparser.encode(input)
          result=data.Internet.postURL(url, inputtext)
        else
          result=nil
        end
        
      else
        data.Error=true
        textresult='Parse Error:'..err
      end
    end
    
    data.result=textresult

    if data.NotifyWhenDone then
      --print("Notifying with result:"..result) 
      synchronize(function()
        if data.NotifyWhenDone then
          data.NotifyWhenDone(data, textresult)
        end
      end)
    end
    
    if not data.WaitForData then
      data.thread=nil
    end
   -- print("thread finished")    
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
 -- print("applyAndSaveKey")
  if f.rbAIAccessPatreon.checked then
    PatreonSessionID=f.edtAPIKEY.text
    s.PatreonSessionID=PatreonSessionID

  elseif f.rbAIAccessPrivate.checked then
    AIKEY=f.edtAPIKEY.text
    if AIKEY~='' then
      s.AIKEY=AIKEY
    end

  end
end

function spawnAIDialog(command, extra) --command and extra are optional
  local animator
  local data={}

  local f=createFormFromFile(basepath..'AIDialog.FRM')
  data.self=f
  data.extra=extra


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
      shellExecute('https://aistudio.google.com/app/api-keys')
    elseif f.rbAIAccessPatreon.checked then
      local sessionid=getCEPatreonSessionID(true)
      if sessionid then
        f.edtAPIKEY.text=sessionid
      end
    end
  end
  
  f.btnSend.OnClick=function(sender)
    --collect the history if there is any (data can be accessed here directly)
    if f.mOutput.Lines.Count>0 then
      f.mOutput.Lines.add('')
    end 

    f.mOutput.Lines.add('> '..f.mInput.Lines.Text)
    f.mInput.Lines.clear()

    f.btnSend.enabled=false
    if f.mOutput.Lines.Count>0 then
      f.mOutput.Lines.add('')
    end
    
    applyAndSaveKey(f)
    
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
    
    if f and f.btnSend then
      f.btnSend.cursor=crHourGlass     
    end

    data.NotifyWhenDone=function(data,r)
      if f and f.btnSend then
        f.btnSend.enabled=true
        animator.Enabled=false
        f.btnSend.Caption=translate('Send')
        f.btnSend.cursor=crDefault
      end
    end
    aiRequest(data, f.mInput.Lines.Text)
  end
  
  local AIAccessChange=function(sender)
    if f.rbAIAccessPublic.Checked then
      f.edtAPIKEY.visible=false
      f.btnObtainKey.visible=false
      f.cbModelSelection.enabled=false
      s.AIAccess='0'
      AIAccess=0
    elseif f.rbAIAccessPatreon.Checked then      
      f.edtAPIKEY.TextHint='<Enter CE Patreon session ID here>'      
      f.edtAPIKEY.Text=PatreonSessionID or ''
      f.edtAPIKEY.visible=true
      f.btnObtainKey.Caption='Refresh session'   
      f.btnObtainKey.visible=true
      f.cbModelSelection.enabled=false
      s.AIAccess='1'
      AIAccess=1
    else
      f.edtAPIKEY.TextHint='<Enter API key here>'
      f.edtAPIKEY.Text=AIKEY or ''
      f.edtAPIKEY.visible=true
      f.btnObtainKey.Caption='Obtain Key'    
      f.btnObtainKey.visible=true
      f.cbModelSelection.enabled=true
      s.AIAccess='2'
      AIAccess=2
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

  if (AIAccess==2) and AIKEY then
    fillModelList(f.cbModelSelection)
  end
  
  -- f.cbModelSelection.OnDropDown=function(sender)
  f.cbModelSelection.OnGetItems=function(sender)
    if AIAccess==2 then
      if f.edtAPIKEY.text~='' then
        applyAndSaveKey(f)      
      end    
    end

    fillModelList(f.cbModelSelection)
    if modelListFetcher then
      if modelListFetcher.Waitfor(1000) then
        modelListFetcher.destroy()
      else
        modelListFetcher.freeOnTerminate(true)
      end
      modelListFetcher=nil
    end
  end
  
  f.Tag=createRef(data) --for storing the history and other useful details


  f.Position=poScreenCenter
  f.Show()
  
  f.mInput.setFocus()

  
  if command then
    f.btnSend.enabled=false 
    data.NotifyWhenDone=function(data,r)
      f.btnSend.enabled=true
    end
    aiRequest(data, command)    
  end

  _G.debug_LastAIForm=f
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

function askAILuaQuestion(command,notifyWhenDone)
  --return a question that returns a luascript that you can execute
  local r,err=askAIQuestion(command,'Only output Cheat Engine Lua Scripts. Omit the lua markdown header', notifyWhenDone)
  
  if r then
    r=r:match('^```lua%s*(.-)%s*```$') or r --just in case it still added the markdown header
    
    --strip lua header if it did add it
    
    
    if (notifyWhenDone==nil) and r==nil and err then 
      return string.format([[messageDialog("%s", mtError)]], err)     
    end
  end;
  
  return r, err
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
        spawnAIDialog([[[The following code is a function copied by Cheat Engine's disassembler. Describe what this function does: 
```
]]..d..[[
```]])
      end
    end
    
  end)
  
  local mi=createMenuItem(MainForm)
  mi.Caption=translate('Ask AI')  
  mi.ImageIndex=MainForm.Menu.Images.add(logo)
  mi.OnClick=function()
    spawnAIDialog()
  end
  MainForm.miHelp.insert(MainForm.miLuaDocumentation.MenuIndex,mi)  
end

initAIMenuItems()