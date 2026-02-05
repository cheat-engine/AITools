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
    return {result=r} 
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

  return {error='not yet implemented'}
    
end

local function ai_getResults(args) --startindex, count
  local scannerid=args.scannerid  
end



registerAITool('getOpenedProcessName','Returns the currently opened processname. (the executable)', {},{},ai_getOpenedProcessName)
registerAITool('openProcess','Opens the the most recent process with this name. Result is true on success', {processname={type='STRING',description='name of the process to open'}},{"processname"},ai_openProcess)
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
                                               
                                              

--nuclear option:
--registerAITool('executeLuaCode','Execute any lua code inside the current Cheat Engine instance', {},{},ai_executeCode)


