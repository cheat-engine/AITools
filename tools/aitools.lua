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
  print("ai_refineScan")
  printf("scannerid=%d", scannerid)
  
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

local function ai_getResultsAndValues(args) --startindex, count
  local scannerid=args.scannerid  
  local startindex=args.startindex
  local count=args.count
  
  local ms=aiobjects[scannerid]
  if ms==nil or ms.ClassName~='TMemScan' then
    print("ai_getResultsAndValues: incorrect scannerid")
    return {error='the scanID was incorrect'}
  end 
  
  local r={}
  local al=createFoundList(ms)
  al.initialize()
  for i=startindex,count do
    local e={}
    e.index=i
    e.address=al.Address[i]
    e.value=al.Value[i]
    
    table.insert(r,e)
  end
  
  al.deinitialize()  
  al.destroy() al=nil
  
  return r
end

function ai_startWatchpoint(args)
  local address=args.address
  local watchsize=args.watchsize or 1
  local watchtype=_G[args.watchtype] or bptAccess  
  
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
        print("bp triggered")
        local instructionPointer
               
        local r={}        
        r.context=debug_getContextTable()
        
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
            
            r.contextExt=debug_getContextTable(true)
            
            --delete from contextExt the nonExt parts
            for name,val in pairs(r.context) do
              r.contextExt[name]=nil
            end
            
            r.stack=readBytes(r.StackPointer,1024, true)
            
            r.stacktrace=stacktrace(r.StackPointer,1024)
            
            
            r.opcode=d.LastDisassembleData.opcode ..' '..d.LastDisassembleData.parameters
            r.opcodesize=#d.LastDisassembleData.bytes
            d.destroy() d=nil            
          end
        end
      end)
      
      if r then
        data.breakpointid=r2
        return {status='success', watchpointID=id}        
      else
        aiobjects[id]=nil --nevermind
        if r2==nil then r2='failure for an unknown reason' end
        return {error=r2}      
      end
    else
      return {error='Failure interpreting what the address `'..address..'` meant'}
    end
  else
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
    if data.type~='watchpoint' then
      return {error='watchpointID corrupted'}
    end
    
    if data.results==nil then
      return {error='watchpointID result data missing'}
    end
    
    for instructionPointer,result in pairs(data.results) do
      local e={}
      e.InstructionAddress=format("%x",result.actualInstructionPointer) --needs to be a string
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
  local datatypes=args.datatypes
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
    
    if datatype.wpRegisters then
      r.registers=e.context
    end
    
    if datatype.wpExtendedRegisters then
      r.extendedRegisters=e.contextExt
    end    
    
    if datatype.wpStackTrace then
      r.stacktrace=e.stacktrace
    end
    
    if datatype.wpStackView then      
      local s=''
      local stackSnapshotSize=args.stackSnapshotSize or 32      
      
      local i=1,stackSnapshotSize do
        s=s..format('%.2x ',e.stack[i])
      end
      
      r.stackview=s
    end
    
    return {status='success', results=r}
  else
    return {error='watchpointID missing'}
  end 
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
                                             scanoption={type='STRING', enum={'soExactValue', 'soValueBetween', 'soBiggerThan', 'soSmallerThan', 'soIncreasedValue', 'soIncreasedValueBy', 'soDecreasedValue', 'soDecreasedValueBy', 'soChanged', 'soUnchanged'},
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
                                                        - soUnchanged: Scan for values that have not changed since last scan  ]]
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

registerAITool('startWatchpoint', [[Sets a watchpoint at a given address so that each time it is hit collects data and then continues the target. The function returns a watchpointID which you can use with the queryWatchPointStatus function and later with the stopWatchpoint function]],
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
                                                        items={'wpFunctionRange', 'wpRegisters','wpExtendedRegisters', 'wpStackTrace', 'wpStackView32', 'wpStackView128', 'wpStackView1024'},
                                                        description=[[A list of optional data to retrieve
                                                          - wpFunctionRange : The start and stop address of the function the instruction is in
                                                          - wpRegisters : The list of general purpose registers and their values. Keep in mind these are from after the instruction was executed
                                                          - wpExtendedRegisters: The extra registers like the floating point unit registers, XMM registers, etc... depending on the architecture
                                                          - wpStackTrace: a stacktrace showing the return addresses
                                                          - wpStackView: a byte snapshot of the stack. Provide stackSnapshotSize else the size will be 32                                                      
                                                        ]]},
                                             stackSnapshotSize={type='INTEGER', description='if datatype wpStackView is present it indicates the number of bytes of the stack snapshot to retrieve. Max 1024'},  
                                             }, --parameters
                                             {'watchpointID','address', 'datatypes'}, --required
                                             ai_getDetailedWatchpointData) --function  
                                             
     

--nuclear option:
--registerAITool('executeLuaCode','Execute any lua code inside the current Cheat Engine instance', {},{},ai_executeCode)


