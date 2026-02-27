--base tools
--MIT License 
--https://github.com/cheat-engine/AITools



local function ai_getOpenedProcessName()
  if process then return {processname=process} else return {processname='no process opened yet'} end
end

local function ai_openProcess(args)
  local processname=args.processname
  
  if processname then
    local r  
    r=openProcess(processname)
    if r then
      return {result='Success', currentProcessID=getOpenedProcessID()}      
    else
      return {error='Failure opening '..processname}
    end
  else
    return {error='No processname provided'}
  end   
end

local function ai_scanMemory(args)
  local value=args.value
  local value2=args.value2
  local scanoption=args.scanoption
  local alignment=args.alignment 
  local vartype=vartype
  local ms=createMemScan()
 
  ms.ScanValue=value
  if vartype then
    ms.VarType=vartype
  end
  
  if scanoption then
    ms.ScanOoption=scanoption
  end
   
  ms.scan()
  
  ms.waitTillDone()
  if ms.ErrorString and ms.ErrorString~='' then
    local err=ms.ErrorString
    ms.destroy()
    return {error='Scan error:'..err}
  end
  
  local i=#aiobjects+1 --perhaps store it in lastData and free when the form and history is deleted
  
  aiobjects[i]=ms
  local r={status='success', scanID=i, foundCount=ms.FoundCount, message='Found '..ms.FoundCount..' results'}
  if ms.FoundCount<=5 then
    r.Addresses={}
    local results=ms.Results
    
    for i=1,#results do      
      r.Addresses[i]=string.format('0x%.8x',results[i])
    end    
  end
  
   
  return r
  --return a scannerid
end

local function ai_refineScan(args)
  local scannerid=args.scanID
 -- print("ai_refineScan")
  --printf("scannerid=%d", scannerid)
  
  local ms=aiobjects[scannerid]
  if ms==nil or ms.ClassName~='TMemScan' then
    print("incorrect scannerid")
    return {error='the scanID was incorrect'}
  end 
  
  ms.value=args.value
  
  if args.scanoption then
    ms.scanoption=args.scanoption
  end
  
  ms.scan()
  ms.waitTillDone()
  
  if ms.ErrorString and ms.ErrorString~='' then
    local err=ms.ErrorString
    ms.destroy()
    return {error='Scan error:'..err}
  end  
  
  local r={status='success', foundCount=ms.FoundCount, message='Found '..ms.FoundCount..' results'}  

  if ms.FoundCount<=5 then
    r.Addresses={}
    local results=ms.Results
    
    for i=1,#results do      
      r.Addresses[i]=string.format('0x%.8x',results[i])
    end    
  end
  return r    
end

function ai_getResultsAndValues(args) --startindex, count
  local scannerid=args.scanID  
  local index=args.index
  local count=args.count
  
  local ms=aiobjects[scannerid]
  if ms==nil or ms.ClassName~='TMemScan' then
    print("ai_getResultsAndValues: incorrect scannerid")
    return {error='the scanID was incorrect'}
  end 
  
  local r={}
  local al=createFoundList(ms)
  al.initialize()
  local maxindex=math.min(al.count-1,index+count-1)
  
  for i=index,maxindex do
    local e={}
    e.index=i
    e.address=al.Address[i]
    e.value=al.Value[i]
    
    table.insert(r,e)
  end
  
  al.deinitialize()  
  al.destroy() al=nil
  
  return {status='success', result=r}
end

function ai_startWatchpoint(args)
  local address=args.address
  local watchsize=args.watchsize or 1
  local watchtype=_G[args.watchtype] or bptAccess  
  
  --autoUpdate ? send a hidden conversation update every few seconds if there's a change ?
  
  --print("ai_startWatchpoint. args=",args)
  
  if address then
    local a=getAddressSafe(address)
    if a then
      local id=#aiobjects+1
      local data={}
      data.type='watchpoint'      
      data.results={}      
      data.resultsLookupActual={}
      aiobjects[id]=data      

      local r,r2=debug_setBreakpoint(a,watchsize,watchtype,function()
        --add to data.result
       -- print("bp triggered")
        local instructionPointer
               
        local r={}        
        r.context=debug_getCurrentContextTable()
        
        if r.context then
          if targetIsX86() then
            if targetIs64Bit() then
              r.InstructionPointer=r.context.RIP 
              r.StackPointer=r.context.RSP
            else
              r.InstructionPointer=r.context.EIP
              r.StackPointer=r.context.ESP
            end            
          elseif targetIsArm() then
            r.InstructionPointer=r.context.PC
            r.StackPointer=r.context.SP
          end 

          if data.results[r.InstructionPointer] then
            r=data.results[r.InstructionPointer]
            r.count=r.count+1
          else
             --first time. get some extra info
            data.results[r.InstructionPointer]=r
            r.count=1          
            
            local start,stop=getFunctionRange(getFunctionRange(r.InstructionPointer))
            r.functionRange={start=start,stop=stop}

            --get the actual instruction pointer
            --test for rep            
            local d=createDisassembler()    
            d.showSymbols=true            
            d.showModules=true
            
            d.disassemble(r.InstructionPointer)
            if d.LastDisassembleData.isRep then
              r.actualInstructionPointer=r.InstructionPointer
            else
              r.actualInstructionPointer=getPreviousOpcode(r.InstructionPointer)
              d.disassemble(r.actualInstructionPointer)
            end
            data.resultsLookupActual[r.actualInstructionPointer]=r --for quick lookup
            
            r.contextExt=debug_getCurrentContextTable(true)
            
            --delete from contextExt the nonExt parts
            for name,val in pairs(r.context) do
              r.contextExt[name]=nil
            end
            
            r.stack=readBytes(r.StackPointer,1024, true)
            
            r.stacktrace=debug_stacktrace(r.StackPointer,1024)
            
            r.opcode=d.LastDisassembleData.opcode ..' '..d.LastDisassembleData.parameters
            r.opcodesize=#d.LastDisassembleData.bytes
            d.destroy() d=nil            
          end
        end
      end)
      
      if r then
        print("ai_startWatchpoint success")
        data.breakpointid=r2
        return {status='success', watchpointID=id}        
      else
       -- print("ai_startWatchpoint failure 1")      
       -- print("r2=",r2)
        aiobjects[id]=nil --nevermind
        if r2==nil then r2='failure for an unknown reason' end
        return {error=r2}      
      end
    else
      print("ai_startWatchpoint failure 2")   
      return {error='Failure interpreting what the address `'..address..'` meant'}
    end
  else
    print("ai_startWatchpoint failure 3")   
    return {error='address was not provided or unparsable'}
  end
end

function ai_stopWatchpoint(args)
  local watchpointID=args.watchpointID
  if watchpointID then
    local data=aiobjects[watchpointID]
    if data then
      if data.type~='watchpoint' then
        return {error='watchpointID corrupted'}
      end
      local r,err=debug_removeBreakpointByID(data.breakpointid)
      if r then
        aiobjects[watchpointID].stopped=true
        return {status='success'}
      else
        if err==nil then      
          return {error='failure removing the watchpoint'}
        else
          return {error=err}
        end
      end
    else
      return {error='watchpointID invalid'}
    end
  else
    return {error='watchpointID missing'}
  end
end

function ai_deleteWatchpoint(args)
  local watchpointID=args.watchpointID
  if watchpointID then
    local data=aiobjects[watchpointID]
    if data.stopped==false then
      local r=ai_stopWatchpoint(args)
      if r.error then
        return r
      end           
    end
    
    aiobjects[watchpointID]=nil
    return {status='success'}
  else
    return {error='watchpointID missing'}
  end
end

function ai_queryWatchPointStatus(args)
  local watchpointID=args.watchpointID
  if watchpointID then
    local r={}
    local data=aiobjects[watchpointID]
    if data==nil then
      return {error='watchpointID is invalid. Did you actually call startWatchpoint?'}
    end
    if data.type~='watchpoint' then
      return {error='watchpointID corrupted'}
    end
    
    if data.results==nil then
      return {error='watchpointID result data missing'}
    end
    
    for instructionPointer,result in pairs(data.results) do
      local e={}
      e.InstructionAddress=string.format("0x%x",result.actualInstructionPointer) --needs to be a string
      e.Opcode=result.opcode
      e.Count=result.count
      
      table.insert(r,e)
    end    
    
    return {status='success', results=r}
  else
    return {error='watchpointID missing'}
  end 
end


function ai_getDetailedWatchpointData(args)
  local watchpointID=args.watchpointID
  local address=getAddressSafe(args.address)
  local indexeddatatypes=args.datatypes

  local datatypes={}
  for i=1,#indexeddatatypes do
    datatypes[indexeddatatypes[i]]=true
  end
  
  --print("ai_getDetailedWatchpointData. args=", args)
  
  if address==nil then
    return {error='address was not provided or unparsable'}
  end
  if watchpointID then
    local data=aiobjects[watchpointID]
    
    if data.type~='watchpoint' then
      return {error='watchpointID corrupted'}
    end
    
    if data.results==nil then
      return {error='watchpointID result data missing'}
    end
    
    local e=data.resultsLookupActual[address]
    if e==nil then
      return {error='invalid address'}
    end
    
    local r={}

    if datatypes.wpFunctionRange then
      r.functionRange=e.functionRange
    end    
    
    if datatypes.wpRegisters then
      r.registers=e.context
    end
    
    if datatypes.wpExtendedRegisters then
      r.extendedRegisters=e.contextExt
    end    
    
    if datatypes.wpStackTrace then
      r.stacktrace=e.stacktrace
    end
    
    if datatypes.wpStackView then      
      local s=''
      local stackSnapshotSize=args.stackSnapshotSize or 32      
      
      for i=1,stackSnapshotSize do
        s=s..format('%.2x ',e.stack[i])
      end
      
      r.stackview=s
    end
    
    return {status='success', results=r}
  else
    return {error='watchpointID missing'}
  end 
end

function ai_disassembleRange(args)
  local start=getAddressSafe(args.startAddress)
  local stop=getAddressSafe(args.stopAddress)
  local showSymbols=args.showSymbols or true
  local showModules=args.showModules or true
  local showSections=args.showSections or false
  
  local d=createDisassembler()
  d.showSymbol=true
  d.showModules=true
  d.showSections=true  
  
  local r={}
  
  local a=start
  while a<=stop do
    local e={}
    d.disassemble(a)
    local ldd=d.LastDisassembleData
    e.address=string.format("0x%x",a)
    e.instruction=ldd.prefix..' '..ldd.opcode..' '..ldd.parameters
    e.addressString=getNameFromAddress(a, true,true,false)
    e.bytes=ldd.bytes
    
    table.insert(r,e)
    
    a=a+#d.LastDisassembleData.bytes
  end  
  
  
  d.destroy() d=nil
  
  return {status='success', result=r}
end

function ai_disassembleSingleInstruction(args)
  local r=ai_disassembleRange({startAddress=args.address, stopAddress=args.address, showSymbols=args.showSymbols, showModules=args.showModules, showSections=args.showSections})
  if r and r.status=='success' and r.result[1] then
    local r2=r.result[1]
    return {status='success',result=r2}
  else
    return {error='disassembling has failed'}
  end
end

function ai_getFunctionRange(args)
  local address=getAddressSafe(args.address)
  
  local start,stop=getFunctionRange(address)
  
  if start and stop then
    return {status='success', start=start, stop=stop}    
  else
    return {error="Failure to get a range. Maybe it's not a function"}    
  end
end

function ai_enumModules(args)
  --list of modulenames, base address and size
  local ml=enumModules()
  local r={}
  for i=1,#ml do
    r[i]={}
    r[i].moduleName=ml[i].Name
    r[i].baseAddress=string.format("0x%x",ml[i].Address)
    r[i].endAddress=string.format("0x%x",ml[i].Address+ml[i].Size)    
  end
  
  return {status='success', moduleList=r}    
end

function ai_getModuleFromAddress(args)
  local address=getAddressSafe(args.address)
  local ml=enumModules()
  for i=1,#ml do
    if (address>ml[i].Address) and (address<ml[i].Address+ml[i].Size) then
      return {status='success', moduleinfo={moduleName=ml[i].Name, baseAddress=string.format("0x%x",ml[i].Address), endAddress=string.format("0x%x",ml[i].Address+ml[i].Size) }}   
    end
  end
  
  return {error="The given address does not belong to a module"}
end

function ai_getModuleSections(args)
  local modulename=args.moduleName
  local sl=enumSectionsOfModule(modulename)
  if sl then
    for i=1,#sl do
      sl[i].FileAddress=nil --less info to confuse it
    end
    return {status='success', sl}
  else
    return {error='Failed retrieving the sections of '..modulename} 
  end        
end

function ai_getTargetedProcessInfo()
  local r={}
  r.is64bit=targetIs64Bit()
  if targetIsAndroid() then
    r.android=true
  end
  
  if targetIsX86() then
    r.x86=true
  end
  
  if targetIsArm() then
    r.arm=true
  end  
  
  if getABI()==0 then
    r.callingConvention='Windows'
  else
    r.callingConvention='System V'
  end
end

local readFunctions={}
readFunctions['vtByte']=function(address) return readByte(address) end
readFunctions['vtWord']=function(address) return readSmallInteger(address) end
readFunctions['vtDword']=function(address) return readInteger(address) end
readFunctions['vtQword']=function(address) return string.format("%x",readQword(address)) end
readFunctions['vtSingle']=function(address) return readFloat(address) end
readFunctions['vtDouble']=function(address) return readString(address) end

local readSizes={}
readSizes['vtByte']=1
readSizes['vtWord']=2
readSizes['vtDword']=4
readSizes['vtQword']=8
readSizes['vtSingle']=4
readSizes['vtDouble']=8


function ai_readMemoryBlock(args)
  local address=getAddressSafe(args.address)
  local elementType=args.elementType
  local count=args.count
  
  if address==nil then
    return {error='Invalid address'}  
  end
  
  local reader=readFunctions[elementType]
  if reader==nil then
    return {error='The elementtype is invalid'}    
  end
  
  local elementSize=readSizes[elementType]
  
  local readerror=false
  local r={}
  for i=1,count do
    local a=address+elementSize*(i-1)
    r[i]=reader(a)
    
    if r[i]==nil then
      readerror=true
    end
  end
  
  if readerror then
    if #r==0 then
      return {error='The memory is unreadable'}
    else
      return {status='partial success. Not all bytes are readable', result=r}
    end
  else  
    return {status='success', result=r}
  end
end

function ai_readString(args)
  local address=getAddressSafe(args.address)
  local widestring=args.widestring or false
  local charcount=args.charcount or 100
  
  if address==nil then
    return {error='Invalid address'}  
  end
  
  return {status='success', result=readString(address, charcount, widestring)}
end

function ai_showLuaScript(args)  
  synchronize(function() 
    local f=createLuaEngine()
    f.mScript.Lines.Text=args.LuaScript or '' 
    f.show()
  end)
  return {status='success'}  
end

function ai_showAutoAssemblerScript(args)  
  synchronize(function() 
    local f=createAutoAssemblerForm()
    f.Assemblescreen.Lines.Text=args.AutoAssemblerScript or ''     
    
  end)  
  
  return {status='success'}
end

function ai_syntaxCheckAutoAssemblerScript(args)  
  local script=args.AutoAssemblerScript
  local enablesection=args.EnableSection or true
  r,r2=autoAssembleCheck(script,enablesection,false)
  
  if not r then
    return {error=r2}  
  else
    return {status='successs'}
  end
end


function ai_getVersionStrings(args)
  s,s2=getFileVersion(enumModules()[1].PathToFile)
  return {s2}
end

function ai_showMemoryView(args)
  synchronize(function() 
    local disassemblerAddress=args.disassemblerAddress
    local hexviewAddress=args.hexviewAddress
    
    getMemoryViewForm().show() 
  end)
  
  return {status='success'}
end

function ai_createMemoryRecord(args)
  local description=args.description 

  
  return synchronize(function()
    local parent=nil
    if args.parentNode then
      local parent=AddressList.getMemoryRecordByID(id)
      if parent==nil then      
        return {error='the parentNode was not valid'}
      end
    end  
  
    local mr=AddressList.createMemoryRecord()
    mr.description=description
    
    if args.script then
      mr.Script=args.script
      
      if args.async then
        mr.Async=args.async
      end    
    else
      if args.address then
        mr.Address=args.address
      end
      
      if args.vartype then
        if args.vartype=='vtWideString' then
          args.vartype='vtUnicodeString'
        end
        mr.VarType=args.vartype
      end
      
      if args.stringSize then
        mr.String.Size=args.stringSize
      end
      
      if args.offsets then
        local i=1,#args.offsets do
          mr.OffsetText[i-1]=args.offsets[i]
        end
      end       
    end  
    
    if parent then
      mr.parent=parent
    end
    return {status='success', memoryRecordID=mr.ID}
  end)
end

function ai_editMemoryRecord(args)
  return synchronize(function()
    local id=args.memoryRecordID
    
    if id then
      local mr=AddressList.getMemoryRecordByID(id)
      if mr then
        local description=args.description
    
        local parent=mr.parent
        if args.parentNode then
          local parent=AddressList.getMemoryRecordByID(id)
          if parent==nil then      
            return {error='the parentNode was not valid'}            
          end
        end

        if args.description then
          mr.description=args.description
        end
        
        if args.script then
          mr.Script=args.script
          
          if args.async then
            mr.Async=args.async
          end    
        else
          if args.address then
            mr.AddressString=args.address
          end
          
          if args.vartype then
            if args.vartype=='vtWideString' then
              args.vartype='vtUnicodeString'
            end
            mr.VarType=args.vartype
          end
          
          if args.stringSize then
            mr.String.Size=args.stringSize
          end
          
          if args.offsets then
            local i=1,#args.offsets do
              mr.OffsetText[i-1]=args.offsets[i]
            end
          end  

          if args.value then
            mr.Value=args.value
          end
          
          if args.active then
            mr.Active=args.active            
          end
        end  
        
        if args.parentNode then
          mr.parent=parent
        end
       
        return {status='success'}        
      else
        return {error='The memoryrecord with the given ID was not found'}        
      end  
    else
      return {error='memoryRecordID parameter was missing'}      
    end
  end)
end

function ai_deleteMemoryRecord(args)
  local id=args.memoryRecordID
  
  return synchronize(function()
    if id then
      return synchronize(function()
        local mr=AddressList.getMemoryRecordByID(id)
        if mr then
          mr.destroy()
          return {status='success'}        
        else
          return {error='The memoryrecord with the given ID was not found'}        
        end
      end)    
    else    
      return {error='memoryRecordID parameter was missing'}
    end
  end)
end

function ai_getAddressList(args)
  function scanNode(node)
    local r={}
    while node do
      local e={}
      e.memoryRecordID=node.memrec.ID
      e.description=node.memrec.Description
      if node.Count>0 then
        e.children=scanNode(node.Items[0])
      end

      table.insert(r,e)

      node=node.getNextSibling()
    end

    return r
  end

  local r
  synchronize(function()
    if AddressList.List.Items.Count>0 then
      r=scanNode(AddressList.List.Items[0])
    else
      r={}
    end
  end)

  return {status='success', list=r}
end

function ai_getMemoryRecordDetails(args)
  local id=args.memoryRecordID
  return synchronize(function()
    if id then
      local mr=AddressList.getMemoryRecordByID(id)
      if mr then
        local r={}
        r.description=mr.Description
        
        if mr.VarType=='vtString' then
          r.stringSize=mr.String.Size
          
          if mr.String.Unicode then
            r.vartype=vtWideString
          else
            r.vartype=vtString
          end
        end     
       
        
        if mr.Script then
          r.script=mr.Script
          r.async=mr.async
        else
          r.address=mr.Address
          local offsets={}
          
          for i=1,mr.OffsetCount do
            offsets[i]=mr.OffsetText[i-1]       
          end        
          if #offsets>0 then
            r.offsets=offsets 
          end
        end
        
        r.value=mr.Value
        
        r.active=mr.Active
        
        if mr.parent then
          r.parent=mr.parent.ID
        end
        
        return {status='success', info=r}
      else
        return {error='The memoryrecord with the given ID was not found'}
      end  
    else
      return {error='memoryRecordID parameter was missing'}
    end  
  end)
end

function ai_getMemoryRecordByDescription(args)
  return synchronize(function()
    local r=AddressList.getMemoryRecordByDescription(args.description)
    if r then
      return {memoryRecordID=r.ID}
    else
      return {error='No memory record with this description found'}
    end
  end)
end



registerAITool('getOpenedProcessName','Returns the currently opened processname. (the executable)', {},{},ai_getOpenedProcessName)
registerAITool('openProcess','Opens the the most recent process with this name. Result is true on success and also provides the processID', {processname={type='STRING',description='name of the process to open'}},{"processname"},ai_openProcess)
registerAITool('scanMemory','Scan for a value and get a scannerID. This scannerID can be used to obtain the results and do a refineScan', 
                                             {value={type='STRING',description='the value to scan for'}, 
                                              value2={type='STRING',description='when scanoption is soValueBetween this determines the second part of the range'}, 
                                              scanoption={type='STRING', enum={'soExactValue', 'soValueBetween', 'soBiggerThan', 'soSmallerThan'},
                                                          description=[[The scan operation to perform
                                                          - soExactValue: Scan for an exact match of the value
                                                          - soValueBetween: Scan for a value between value and value2 
                                                          - soBiggerThan: Scan for values bigger than the given value
                                                          - soSmallerThan: Scan for values smaller than the given value]]
                                                         },
                                              vartype={type='STRING', enum={'vtByte', 'vtWord', 'vtDword', 'vtQword', 'vtSingle', 'vtDouble', 'vtString', 'vtByteArray', 'vtGrouped', 'vtBinary', 'vtAll'},
                                                       description=[[The data type to scan for 
                                                        - vtByte: 1-byte integer (0-255)
                                                        - vtWord: 2-byte integer
                                                        - vtDword: 4-byte integer (default. Standard for most game values). 
                                                        - vtQword: 8-byte integer
                                                        - vtSingle: 4-byte floating point 
                                                        - vtDouble: 8-byte floating point 
                                                        - vtString: ascii string scan
                                                        - vtGrouped: a cheat engine groupscan formatted string
                                                        - vtByteArray: A sequence of hex bytes (AOB)
                                                        - vtBinary: Scans for the given value's binary value inside the memory. Best used for big values that take up at least 1 byte
                                                        - vtAll: Scans the most common types at the same time (vtDword, vtSingle, vtDouble)]]
                                                      },
                                              alignment={type='INTEGER', description='What memory alignment should be used. Default is 4'}
                                              },
                                              {'value'}, --required
                                              ai_scanMemory) --function
                                              
                                              
registerAITool('refineScan', 'refines a previously made scan', 
                                             {
                                             scanID={type='INTEGER', description='the scanID returned by the initial call to scanMemory'},
                                             value={type='STRING',description='the value to scan for or use depending on the scanoption'}, 
                                             scanoption={type='STRING', enum={'soExactValue', 'soValueBetween', 'soBiggerThan', 'soSmallerThan', 'soIncreasedValue', 'soIncreasedValueBy', 'soDecreasedValue', 'soDecreasedValueBy', 'soChanged', 'soUnchanged', 'soReadable'},
                                                         description=[[The scan operation to perform
                                                        - soExactValue: Scan for an exact match of the value
                                                        - soValueBetween: Scan for a value between value and value2 
                                                        - soBiggerThan: Scan for values bigger than the given value
                                                        - soSmallerThan: Scan for values smaller than the given value
                                                        - soIncreasedValue: Scan for values that have increased since last scan
                                                        - soIncreasedValueBy: Scan for values that have increased by value since last scan
                                                        - soDecreasedValue: Scan for values that have been decreased since last scan
                                                        - soDecreasedValueBy: Scan for values that have been decreased by value sinze last scan
                                                        - soChanged: Scan for values that have been changed since last scan
                                                        - soUnchanged: Scan for values that have not changed since last scan  
                                                        - soForgot: Scan for values that are readable. Handy for cases the user got distracted and doesn't know if the value got changed or not]]
                                                        },                                                        
                                              },
                                              {'scanID', 'value'}, --required
                                              ai_refineScan) --function
                                              
registerAITool('getResultsAndValues', [[Retrieves a view of the results of the given scanID. each entry has: 
                                          - address: It holds the address in hexadecimal string format and for the ALL type it also contains an identifier what type it is 
                                          - value : The value this address currently holds. the value '???' means it is unreadable
                                          - index : the index number of the results ]],                                           
                                             {
                                             scanID={type='INTEGER', description='the scanID returned by the initial call to scanMemory'},
                                             index={type='INTEGER',description='The start index of the results. Index starts at 0'}, 
                                             count={type='INTEGER',description='The number of results to retrieve'}
                                             }, --parameters
                                             {'scanID', 'index', 'count'}, --required
                                             ai_getResultsAndValues) --function                  

registerAITool('startWatchpoint', [[Sets a watchpoint at a given address so that each time it is hit it collects data and then continues the target. 
                                    When called the function returns a watchpointID which you can use with the queryWatchPointStatus function and later with the stopWatchpoint function
                                    After having obtained a valid watchpointID (>0) tell the user to do things in the game to trigger the watchpoint and tell you when done ]],
                                             {
                                             address={type='STRING', description='The address to watch for memory accesses. Formatted as hexadecimal or a symbol recognized by Cheat Engine'},                 
                                             watchsize={type='INTEGER', description='The size in bytes for the watchpoint. default 1'},
                                             watchtype={type='STRING', enum={'bptAccess','bptWrite'}, 
                                                        description=[[What kind of watch to use. 
                                                                        - bptAccess: will record every access (default if not set)
                                                                        - bptWrite will only record writes]] }
                                             }, --parameters
                                             {'address'}, --required
                                             ai_startWatchpoint) --function         
                                               
     
registerAITool('stopWatchpoint', [[Stops a previously created watchpoint but doesn't delete the data yet]],
                                             {
                                             watchpointID={type='INTEGER', description='The watchpointID returned by startWatchpoint'},                                                              
                                             }, --parameters
                                             {'watchpointID'}, --required
                                             ai_stopWatchpoint) --function  
                                             
registerAITool('deleteWatchpoint', [[Stops a previously created watchpoint if it wasn't stopped yet, and deletes the gathered data. The watchpointID will be invalid after that]],
                                             {
                                             watchpointID={type='INTEGER', description='The watchpointID returned by startWatchpoint'},                                                              
                                             }, --parameters
                                             {'watchpointID'}, --required
                                             ai_deleteWatchpoint) --function                                               
                                             
registerAITool('queryWatchPointStatus', [[Retrieves a list of entries containing the instruction address, the opcode and the number of times that instruction was encountered during the watchpoint recording. The InstructionAddress can be used with getDetailedWatchpointData to obtain more information]],
                                             {
                                             watchpointID={type='INTEGER', description='The watchpointID returned by startWatchpoint'},                                                              
                                             }, --parameters
                                             {'watchpointID'}, --required
                                             ai_queryWatchPointStatus) --function  
                                             
registerAITool('getDetailedWatchpointData', [[Retrieves detailed data about a watchpoint]],
                                             {
                                             watchpointID={type='INTEGER', description='The watchpointID returned by startWatchpoint'},                                                              
                                             address={type='STRING', description='The instruction address returned by queryWatchPointStatus'},                                                                                                           
                                             datatypes={type="ARRAY", 
                                                        items={
                                                          type='STRING',
                                                          enum={'wpFunctionRange', 'wpRegisters','wpExtendedRegisters', 'wpStackTrace', 'wpStackView'}
                                                          },
                                                        description=[[A list of optional data to retrieve
                                                          - wpFunctionRange : The start and stop address of the function the instruction is in
                                                          - wpRegisters : The list of general purpose registers and their values. Keep in mind these are from after the instruction was executed
                                                          - wpExtendedRegisters: The extra registers like the floating point unit registers, XMM registers, etc... depending on the architecture
                                                          - wpStackTrace: a stacktrace showing the return addresses
                                                          - wpStackView: a byte snapshot of the stack formatted as a list of bytes. Provide stackSnapshotSize else the size will be 32                                                      
                                                        ]]},
                                             stackSnapshotSize={type='INTEGER', description='if datatype wpStackView is present it indicates the number of bytes of the stack snapshot to retrieve. Max 1024'},  
                                             }, --parameters
                                             {'watchpointID','address', 'datatypes'}, --required
                                             ai_getDetailedWatchpointData) --function  
                                             
registerAITool('disassembleRange', [[Disassembles a range of code using the cheat engine disassembler. It returns a list of entries each containing the address in hexadecimal format, the addressString as it would be shown by the show* parameters, the bytes that make up the instruction, and the instruction itself]],
                                             {
                                             startAddress={type='STRING', description='The address to start disassembling from (supports cheat engine symbols)'},                                                              
                                             stopAddress={type='STRING', description='The end of the disassembly'},                                                              
                                             showSymbols={type='BOOLEAN', description='Show symbols for addresses. Default=true'},
                                             showModules={type='BOOLEAN', description='Show modulename+offset notation for addresses (if no symbol is found and showSymbols was true). Default=true'},
                                             showSections={type='BOOLEAN', description='Show `modulename.sectionname+offset` for addresses.  overrides showModules when true. Default=false'},    
                                             }, --parameters
                                             {'startAddress','stopAddress'}, --required
                                             ai_disassembleRange) --function  
                                             
registerAITool('disassembleInstruction', [[Disassembles a single instruction. It contains the address in hexadecimal format, the addressString as it would be shown by the show* parameters, the bytes that make up the instruction, and the instruction itself]],
                                             {
                                             address={type='STRING', description='The address to start disassembling from (supports cheat engine symbols)'},                                                                                                           
                                             showSymbols={type='BOOLEAN', description='Show symbols for addresses. Default=true'},
                                             showModules={type='BOOLEAN', description='Show modulename+offset notation for addresses (if no symbol is found and showSymbols was true). Default=true'},
                                             showSections={type='BOOLEAN', description='Show `modulename.sectionname+offset` for addresses.  overrides showModules when true. Default=false'},    
                                             }, --parameters
                                             {'address'}, --required
                                             ai_disassembleSingleInstruction) --function                                               
                                             
registerAITool('getFunctionRange', [[Gets the range of the function the given address belongs to]],
                                             {
                                             address={type='STRING', description='The address to inspect'},                                                                                                           
                                             }, --parameters
                                             {'address'}, --required
                                             ai_getFunctionRange) --function     
                                             
registerAITool('enumModules', [[Gets the list of modules currently loaded in the game.  You can assume that the first one is the main executable.  Each entry contains the name, baseAddress and endAddress of each loaded module]],
                                             {                                                                                                                                                        
                                             }, --parameters (none)
                                             {}, --required
                                             ai_enumModules) --function  
                                             
registerAITool('getModuleFromAddress', [[If the address belongs to a module, this returns the module name, it's baseAddress and endAddress ]],
                                             {  
                                                address={type='STRING', description='The address to inspect'},                                               
                                             }, 
                                             {address}, --required
                                             ai_getModuleFromAddress) --function                                               

registerAITool('getModuleSections', [[Gets the section list of the specified module and their specifics]],
                                             {
                                             moduleName={type='STRING', description='The name of the module to retrieve the sections from'},
                                             }, --parameters
                                             {'moduleName'}, --required
                                             ai_getFunctionRange) --function

registerAITool('getTargetedProcessInfo', [[Gets architecture information about the target process: The calling convention, if the target is 64-bit, if it's ARM or x86, and if it's android or not]],
                                             {                                                                                                                                           
                                             }, --parameters
                                             {}, --required
                                             ai_getTargetedProcessInfo) --function     
                                             
registerAITool('readMemoryBlock', [[Reads memory in specific sizes and formats]],
                                             {
                                             address={type='STRING', description='The address to start the read from (Supports cheat engine symbols)'},
                                             elementType={type='STRING', enum={'vtByte', 'vtWord', 'vtDword', 'vtQword', 'vtSingle', 'vtDouble'},
                                                       description=[[The element type to read
                                                        - vtByte: 1-byte integer
                                                        - vtWord: 2-byte integer
                                                        - vtDword: 4-byte integer
                                                        - vtQword: 8-byte integer (returns as strings to deal with json number issues for 64-bit values)
                                                        - vtSingle: 4-byte floating point 
                                                        - vtDouble: 8-byte floating point 
                                                        ]]},
                                             count={type='INTEGER', description='The number of elements to read'}
               
                                             }, --parameters
                                             {'address','elementType','count'}, --required
                                             ai_readMemoryBlock) --function      

registerAITool('readString', [[Reads a string of memory from a memory address]],
                                             {
                                             address={type='STRING', description='The address to start the read from (Supports cheat engine symbols)'},                                             
                                             charcount={type='INTEGER', description='The number of characters to read (default 100 or 0-terminator. whatever comes first)'},
                                             widestring={type='BOOLEAN', description='If true the address points to a string of widechar characters'}
                                             }, --parameters
                                             {'address'}, --required
                                             ai_readString) --function     

               

               
registerAITool('showLuaScript',[[Opens a lua engine window and inserts the provided lua script in the editor field]],{LuaScript={type='STRING', description='The script to show in the editor section)'}},{'LuaScript'},ai_showLuaScript)                                         

registerAITool('showAutoAssemblerScript',[[Opens an autoAssembler windows and inserts the provides auto assembler script in the editor field]],{AutoAssemblerScript={type='STRING', description='The script to show in the editor section)'}},{'AutoAssemblerScript'},ai_showAutoAssemblerScript)                                         

registerAITool('syntaxCheckAutoAssemblerScript',[[Checks the given auto assembler script if it will error out when assembling in the current state]],{
                                                                                                                                                      AutoAssemblerScript={type='STRING', description='The autoassembler script to check)'},
                                                                                                                                                      EnableSection={type='boolean', description='Check the enable section when true or not provided. If false, the disable section will be checked.  If there is no disable or enable section the script will be handled as an enable section'}                                                                                                                                                      
                                                                                                                                                      },{'AutoAssemblerScript'},ai_syntaxCheckAutoAssemblerScript)                                         


registerAITool('openMemoryView',[[Opens the memory view window]],{disassemblerAddress={type='STRING', description='The address for the disassembler'},
                                                                  hexviewAddress={type='STRING', description='The hexadecimal address for the disassembler'} 
                                                                 },{},ai_showMemoryView)    
                                                                 
registerAITool('getVersionStrings',[[Retrieves the version resource strings of the target process. This includes, ProductVersion, FileDescription, InternalName, etc...]],{},{},ai_getVersionStrings)                                         

registerAITool('createMemoryRecord',[[Creates a new memory record and adds it to the main address list. It returns a memoryRecordID which will never change. Not when the user renames it and not when the user changes the order]], 
                                          {
                                          --params
                                          description={type='STRING', description='The memory record description/name'},
                                          vartype={type='STRING', enum={'vtByte', 'vtWord', 'vtDword', 'vtQword', 'vtSingle', 'vtDouble', 'vtString', 'vtWideString'},
                                                       description=[[The variable type of the memory record
                                                        - vtByte: 1-byte integer
                                                        - vtWord: 2-byte integer
                                                        - vtDword: 4-byte integer (Default)
                                                        - vtQword: 8-byte integer
                                                        - vtSingle: 4-byte floating point 
                                                        - vtDouble: 8-byte floating point 
                                                        - vtString: an utf8 encoded string
                                                        - vtWideString: a widestring
                                                        - vtAutoAssembler : autoassembler script
                                                        ]]},
                                                        
                                          stringSize={type='INTEGER', description='The number of characters for the string if a string type'},
                                                        
                                          
                                          address={type='STRING', description='The address/baseaddress of the record in hexadecimal notation. Omit the 0x part in front. This field can also contain known symbols to Cheat Engine'},                                                        
                                          offsets={type='ARRAY', items={type='STRING'}, description=[[When set the address will be handled as a pointer address/
                                                                                                     It is a list of offsets(hexadecimal values(no 0x in front), interpretable symbols or lua code)
                                                                                                     During runtime, the first offset's value gets added to the baseAddress's value (in 32-bit 4 bytes, in 64-bit 8 bytes) : P1
                                                                                                     If there is a 2nd offset, P1 will get read as a pointer and the value of the 2nd offset will be added to that : P2
                                                                                                     This repeats until the last offset. The final address will then become the last pointer(Px)+lastoffset]]},
                                          
                                          script={type='STRING',description='An autoassembler script with [ENABLE] and [DISABLE] tags. It triggers when the Active checkbox gets checked/unchecked.  If set, vartype of vtAutoAssembler is assumed'},
                                          async={type='BOOLEAN', description='If true the autoassembler script will run in a seperate thread when activating, not freezing the user\'s UI'},
                                          parentNode={type='INTEGER', description='The parent memoryRecordID'}
                                          }
                                          ,
                                          {
                                          --required
                                          'description'
                                          }
                                          ,
                                          ai_createMemoryRecord)

registerAITool('deleteMemoryRecord',[[Deletes a memoryrecord with the given memoryRecordID]],
                                          {
                                          --params
                                          memoryRecordID={type='INTEGER', description='The unique identifier of a memoryrecord in the addresslist'},
                                          }
                                          ,
                                          {
                                          --required
                                          'memoryRecordID'
                                          }
                                          ,
                                          ai_deleteMemoryRecord)
                                          
registerAITool('getAddressList',[[Returns the current addreslist layout. Each entry contains the description and the unique memoryRecordID]],{},{},ai_getAddressList)
                                          
registerAITool('getMemoryRecordDetails',[[Get details like the description, vartype, address, offsets, script, parent, value, active state etc... for the given memoryRecord. See createMemoryRecord for details]],
                                          {
                                          --params
                                          memoryRecordID={type='INTEGER', description='The unique identifier of a memoryrecord in the addresslist'},
                                          }
                                          ,
                                          {
                                          --required
                                          'memoryRecordID'
                                          }
                                          ,
                                          ai_getMemoryRecordDetails)
                                          
registerAITool('editMemoryRecord',[[edits an existing memory record identified by it's memoryRecordID]], 
                                          {
                                          --params
                                          memoryRecordID={type='INTEGER', description='The unique identifier of a memoryrecord in the addresslist'},
                                          description={type='STRING', description='The new description/name of the memory record'},
                                          vartype={type='STRING', enum={'vtByte', 'vtWord', 'vtDword', 'vtQword', 'vtSingle', 'vtDouble', 'vtString', 'vtWideString'},
                                                       description=[[The new variable type of the memory record
                                                        - vtByte: 1-byte integer
                                                        - vtWord: 2-byte integer
                                                        - vtDword: 4-byte integer
                                                        - vtQword: 8-byte integer
                                                        - vtSingle: 4-byte floating point 
                                                        - vtDouble: 8-byte floating point 
                                                        - vtString: an utf8 encoded string
                                                        - vtWideString: a widestring
                                                        - vtAutoAssembler : autoassembler script
                                                        ]]},
                                                        
                                          stringSize={type='INTEGER', description='The new maximum number of characters for the string if a string type'},
                                                        
                                          
                                          address={type='STRING', description='The new address/baseaddress of the record in hexadecimal notation. Omit the 0x part in front. This field can also contain known symbols to Cheat Engine'},                                                        
                                          offsets={type='ARRAY', items={type='STRING'}, description=[[When set the address will be handled as a pointer address/
                                                                                                     It is a list of offsets(hexadecimal values(no 0x in front), interpretable symbols or lua code)
                                                                                                     During runtime, the first offset's value gets added to the baseAddress's value (in 32-bit 4 bytes, in 64-bit 8 bytes) : P1
                                                                                                     If there is a 2nd offset, P1 will get read as a pointer and the value of the 2nd offset will be added to that : P2
                                                                                                     This repeats until the last offset. The final address will then become the last pointer(Px)+lastoffset]]},
                                          
                                          script={type='STRING',description='The updated/new autoassembler script with [ENABLE] and [DISABLE] tags'},
                                          async={type='BOOLEAN', description='Changes the async variable. If true the autoassembler script will run in a seperate thread when activating, not freezing the user\'s UI'},
                                          parentNode={type='INTEGER', description='Sets a new parent. null if you want it to be at the root'},
                                          value={type='STRING', description='Sets the value of the memory record.  If it was frozen this will update the value it freeze at.  You can also set the value to (MemoryRecordDescription) and it will set the value to the same value as the memoryrecord with the given description'},
                                          active={type='BOOLEAN', description=[[If the valuetype isn't vtAutoAssembler then when set to true will freeze the value to the current value, and when false unfreeze the value
                                                                               If it is sa vtAutoAssembler setting this to true will assemble the [ENABLE] section. On false it will execute the [DISABLE] section]]}
                                          }
                                          ,
                                          {
                                          --required
                                          'memoryRecordID'
                                          }
                                          ,
                                          ai_editMemoryRecord)
                                          
registerAITool('getMemoryRecordByDescription',[[Returns a unique never changing memoryRecordID with the given description/name]],{description={type='STRING', description='The description of the memory record to look for'}},{'description'},ai_getMemoryRecordByDescription)
                                               

                                          


--nuclear option (and halicinary):
--registerAITool('executeLuaCode','Execute any lua code inside the current Cheat Engine instance', {script},{},ai_executeCode)


