classdef HomeIO < handle
    %HOME I/O Communications class
    %   Grants simple access to all inputs, outputs and memories

    % PLEASE NOTE: HomeIO object MUST descend from handle class!
    % https://www.mathworks.com/matlabcentral/answers/183246-updating-property-of-an-object-without-creating-new-object

    properties
        % Structs may not be populated in properties: declare them and
        % populate on object construction

        % Raw data as per the Excel spreadsheet, plus columns
        BaseData;

        % Will hold full data with values
        FullData;

        % Will hold full Inputs, Outputs, Memories
        % and Bools, Floats, DateTimes and combinations
        Types = struct();
        %Inputs;
        %Outputs;
        %Memories;
        %Bools;
        %Floats;
        %DateTimes;

        %InputBools;
        %InputFloats;
        %InputDateTimes;
        %OutputBools;
        %OutputFloats;
        %OutputDateTimes;
        %MemoryBools;
        %MemoryFloats;
        %MemoryDateTimes;

        % Will hold all data for a specified Zone (room)
        Zones = struct();
        %ZoneA;
        %ZoneB;
        %ZoneC;
        %ZoneD;
        %ZoneE;
        %ZoneF;
        %ZoneG;
        %ZoneH;
        %ZoneI;
        %ZoneJ;
        %ZoneK;
        %ZoneL;
        %ZoneM;
        %ZoneN;
        %ZoneO;
        %ZoneNone;

        % Will Hold devices akin
        Devices = struct();

        % Inputs category
        %LightSwitches;
        %UpDownSwitches;
        %LightDimmersUpDown;
        %DoorDetectors;
        %MotionDetectors;
        %BrightnessSensorsBool;
        %SmokeDetectors;
        %AlarmKeyPadArmed;
        %GarageDoorSensors;
        %EntranceGateSensors;
        %RemoteButtons;
        %BrightnessSensorsFloat;
        %ThermostatTemperatures;
        %ThermostatSetPoints;
        %RollerShades;
        %DateAndTimeInput;

        % Outputs category
        %LightsBool;
        %LightsFloat;
        %RollerShadesUpDown;
        %HeatersFloat;
        %HeatersBool;
        %Sirens;
        %AlarmKeyPad;
        %GarageDoorOpenClose;
        %EntranceGate;

        % Memories category
        %DLST;
        %TimeScale;
        %LatLongitude;
        %EnvironmentValues;
        %InstantPower;
        %CurrentPower;
        %LastPower;
        %ZoneTemperatures;
        %DateAndTimeMemory;

        % Other special, possibly useful classifications
        Special = struct()
        %InputsNC;
        %InputsNO;
        %Inputs10V;
        %Outputs10V;
        %ConflictInputs;
        %ConflictOutputs;
        %BoolFloatOutputs;

        % Use this methods' checkMember and mustMember to check for row membership

        % --------------------------------
        % Communication items: Listener handler objects and a timer object
        Comm = struct();
        %lh1;
        %lh2;
        %lh3;
        %t; %timer

        % Configs, save just in case
        Config = struct();
        % engineio_path
        % data_path
        % set_timer
        % set_listener

    end

    methods
        function obj = HomeIO(varargin)
            %HOMEIO Constructor
            %   Prepares the class by running the .NET dependency and
            %   updating the MemoryMap once if Home I/O is running
            %   Also allows specifying a non-default path for finding the
            %   Engine I/O DLL library and capability to update data via a
            %   timer or externally


            %% Parse inputs
            default_engineio_path = strcat(pwd,'\EngineIO.dll');
            default_data_path     = strcat(pwd,'\homeio_full.xlsx');
            default_timer         = false;
            default_listen        = true;

            p = inputParser;
            p.addParameter('engineio_path',default_engineio_path,@mustBeFile);
            p.addParameter('data_path',default_data_path,@mustBeFile);
            p.addParameter('set_timer',default_timer,@mustBeNumericOrLogical);
            p.addParameter('set_listener',default_listen,@mustBeNumericOrLogical);
            p.parse(varargin{:});

            obj.Config.engineio_path = p.Results.engineio_path;
            obj.Config.data_path     = p.Results.data_path;
            obj.Config.set_timer     = p.Results.set_timer;
            obj.Config.set_listener  = p.Results.set_listener;

            %% Prepare required libraries and data
            % Link Engine I/O library now (ensures the correct path)
            obj.connectHomeIO(obj.Config.engineio_path);

            % Read and prepare all data from the table (same with path)
            obj.BaseData = obj.readExcelData(obj.Config.data_path);

            % Adapt power consumption to work with the estimatePower method
            % for outputs that are in range 0-10V
            obj.changePower10V();

            % Split data into fixed groups
            obj.splitData();

            % Add a column to store values, DateTime values must be stored
            % in numerical form (if ever rendered usable). In another
            % variable to preserve table data structure
            obj.FullData = obj.BaseData;
            obj.FullData.Value = nan(height(obj.FullData),1);

            % Check Home I/O, update, preload values
            % Just warn, in case we are working offline
            if obj.checkHomeIO("action","warning")
                obj.updateHomeIO();
                
                obj.FullData.Value = obj.readValues();
                
                % Read again after a couple frames: 
                % for unknown reasons, 1st read is always wrong 
                pause(2/60)
                obj.updateHomeIO();
                obj.FullData.Value = obj.readValues();
            end

            %% Event listeners and timer setup

            % Listeners if specified
            if obj.Config.set_listener
                obj.Comm.lh1 = listener(EngineIO.MemoryMap.Instance,'InputsValueChanged',@obj.OnValuesChanged);
                obj.Comm.lh2 = listener(EngineIO.MemoryMap.Instance,'OutputsValueChanged',@obj.OnValuesChanged);
                obj.Comm.lh3 = listener(EngineIO.MemoryMap.Instance,'MemoriesValueChanged',@obj.OnValuesChanged);
            end

            % Timer if specified
            if obj.Config.set_timer
                obj.Comm.t = timer;
                obj.Comm.t.BusyMode = 'drop'; % maybe 'queue' could fit other needs 
                obj.Comm.t.ExecutionMode = 'fixedRate';
                obj.Comm.t.Period = 1000/1000; % in seconds
                %obj.Comm.t.Period = 1/60; % Warning: max precision = 1 millisecond
                %obj.Comm.t.TasksToExecute = 100; % For non permanent timers

                if obj.Config.set_listener
                    obj.Comm.t.TimerFcn = @obj.OnTimerCall;
                else
                    obj.Comm.t.TimerFcn = @obj.OnTimerCallNoListener;
                end

                %tic; % Uncomment this and all toc for performance measurements
                start(obj.Comm.t);
            end
        end

        function out = checkHomeIO(obj,varargin)
            %checkHomeIO checks if Home I/O is running and warns or errors
            %   if appropriate value is supplied

            %% Parse inputs
            default_action = 'none';

            p = inputParser;
            p.addParameter('action',default_action,@mustBeText);
            p.parse(varargin{:});

            action = p.Results.action;
            mustBeMember(action,{'warning','error','none'});

            % Fast approach with included .NET object
            %https://www.mathworks.com/matlabcentral/answers/40617-how-to-find-the-process-id-pid-in-matlab
            out = System.Diagnostics.Process.GetProcessesByName("Home IO").Length;

            if action ~= "none" && out ~=1
                if action == "warning"
                    warning('Unable to find Home I/O process or Home I/O running more than once. Results might be inaccurate.')
                    out = 0;
                elseif action == "error"
                    obj.delete()
                    error('Unable to find Home I/O process or Home I/O running more than once. Stopping...')
                end
            end
        end

        function values = readValues(obj,varargin)
            %Reads values from the supplied array in the argument. If no
            %   argument is provided, reads memories from every line
            %   included in the base data property (obj.BaseData)

            %% Parse inputs
            default_data = obj.BaseData;

            p = inputParser;
            p.addOptional('data',default_data); % Must be member of BaseData
            p.parse(varargin{:});

            data = p.Results.data;
            obj.mustMember(data,obj.BaseData);

            %% Work with data

            % Preset values with NaN of correct size
            values = nan(height(data),1);

            % Attempt at speeding up more: switch-case method
            for i=1:height(data)
                switch data.VarType(i)
                    case 1
                        values(i) = EngineIO.MemoryMap.Instance.GetBit(data.Address(i), EngineIO.MemoryType.Input).Value;
                    case 2
                        values(i) = EngineIO.MemoryMap.Instance.GetFloat(data.Address(i), EngineIO.MemoryType.Input).Value;
                    case 3
                        % Datenum accepts double values only
                        temp = EngineIO.MemoryMap.Instance.GetDateTime(data.Address(i), EngineIO.MemoryType.Input).Value;
                        temp = double([temp.Year temp.Month temp.Day temp.Hour temp.Minute temp.Second+temp.Millisecond/1000]);
                        values(i) = datenum(temp(1), temp(2), temp(3), temp(4), temp(5), temp(6));

                    case 4
                        values(i) = EngineIO.MemoryMap.Instance.GetBit(data.Address(i), EngineIO.MemoryType.Output).Value;
                    case 5
                        values(i) = EngineIO.MemoryMap.Instance.GetFloat(data.Address(i), EngineIO.MemoryType.Output).Value;
                    case 6 % Does never happen but to keep code consistency
                        % Datenum accepts double values only
                        temp = EngineIO.MemoryMap.Instance.GetDateTime(data.Address(i), EngineIO.MemoryType.Output).Value;
                        temp = double([temp.Year temp.Month temp.Day temp.Hour temp.Minute temp.Second+temp.Millisecond/1000]);
                        values(i) = datenum(temp(1), temp(2), temp(3), temp(4), temp(5), temp(6));

                    case 7
                        values(i) = EngineIO.MemoryMap.Instance.GetBit(data.Address(i), EngineIO.MemoryType.Memory).Value;
                    case 8
                        values(i) = EngineIO.MemoryMap.Instance.GetFloat(data.Address(i), EngineIO.MemoryType.Memory).Value;
                    case 9
                        % Datenum accepts double values only
                        temp = EngineIO.MemoryMap.Instance.GetDateTime(data.Address(i), EngineIO.MemoryType.Memory).Value;
                        temp = double([temp.Year temp.Month temp.Day temp.Hour temp.Minute temp.Second+temp.Millisecond/1000]);
                        values(i) = datenum(temp(1), temp(2), temp(3), temp(4), temp(5), temp(6));
                    otherwise
                        error("Unrecognized case: got an unknown value at data row %i",i);
                end
            end
            % returns values
        end

        function out = getRows(obj,varargin)
            %getRows fetches appropriate rows from the obj.FullData 
            %   property. If no data array is supplied, returns the full 
            %   table of obj.FullData

            %% Parse inputs
            default_data = obj.BaseData;

            p = inputParser;
            p.addOptional('data',default_data); % Must be member of BaseData
            p.parse(varargin{:});

            data = p.Results.data;
            mustBeMember(data,obj.BaseData);

            %% Select and return rows from obj.FullData
            out = obj.getRowsFromRowIDs(data.RowID);

        end

        function out = getRowsFromRowIDs(obj,rows)
            % Called from getRows or directly, faster but refuses calls
            % without argument for safety reasons (ie avoid made up rowIDs)
            p = inputParser;
            p.addRequired('rows',@mustBeNumeric);
            p.parse(rows);
            
            out = obj.FullData(rows,:);
        end

        function out = getValues(obj,varargin)
            %getValues fetches current values (only) from the rows of the
            %   obj.FullData property. If no data array is supplied,
            %   returns the full values table of obj.FullData

            %% Parse inputs
            default_data = obj.BaseData;

            p = inputParser;
            p.addOptional('data',default_data); % Must be member of BaseData
            p.parse(varargin{:});

            data = p.Results.data;
            mustBeMember(data,obj.BaseData);

            %% Select and return values from obj.FullData
            out = obj.getValuesFromRowIDs(data.RowID);

        end

        function out = getValuesFromRowIDs(obj,rows)
            % Called from getRows or directly, faster but refuses calls
            % without argument for safety reasons (ie avoid made up rowIDs)
            p = inputParser;
            p.addRequired('rows',@mustBeNumeric);
            p.parse(rows);
            
            out = obj.FullData.Value(rows);
        end

        function setValues(obj,data,values,varargin)
            %setValues sets values to specified data. Only works for Output
            %   values as these are the only settable (gives a warning
            %   otherwise).
            %   Required parameters: data and values;
            %   Optional parameters: CheckConflicts deactivates conflicting
            %   outputs (for example open and close garage door, keeps the
            %   last one); CapValues caps Bool values to integer 0-1 and
            %   Float values that have 0-10 limits

            %% Parse inputs

            def_conflicts   = true;
            def_capvalues   = true;
            def_update      = true;
            def_checkHomeIO = true;

            p = inputParser;
            p.addRequired("data")  % Unable to find verif. function
            p.addRequired("values") % Same
            p.addParameter("checkConflicts",def_conflicts,@mustBeNumericOrLogical)
            p.addParameter("capValues",def_capvalues,@mustBeNumericOrLogical)
            p.addParameter("update",def_update,@mustBeNumericOrLogical)
            p.addParameter("checkHomeIO",def_checkHomeIO,@mustBeNumericOrLogical)

            p.parse(data,values,varargin{:});

            data           = p.Results.data;
            values         = p.Results.values;
            checkConflicts = p.Results.checkConflicts;
            capValues      = p.Results.capValues;
            update         = p.Results.update;
            checkHomeIO    = p.Results.checkHomeIO;

            %% Check HomeIO since this petition can come from outside, 
            % also check and sanitize other variable issues
            if checkHomeIO
                obj.checkHomeIO("action","error");
            end

            obj.mustMember(data,obj.Types.Outputs);
            mustBeNumericOrLogical(values); % NaNs get hunted later

            % Reject if no coincidence in heights
            n = height(data);
            if height(values) ~= n
                error("Height of data (%d) does not match with height of values provided (%d)",n,height(values))
            end

            %% Process values
            % Prepare checks for membership for all the data array in a 
            % timely manner
            if capValues
                % Just a logical value works
                capRows = obj.checkMember(data,obj.Special.Outputs10V);
            end
            if checkConflicts
                % We need the row value here
                [~,conflictRows] = obj.checkMember(data,obj.Special.ConflictOutputs);
                [~,BoolFloatRows] = obj.checkMember(data,obj.Special.BoolFloatOutputs);
            end
            
            % Get the home devices and set the values in different steps.

            for i=1:n    
                % Get device type and address to temp var (no table)
                % Addresses must be extracted from the table too
                type = data.DataType(i); % "Bool", "Float", no "DateTime"
                addr = data.Address(i);

                if type == "Bool"
                    device = EngineIO.MemoryMap.Instance.GetBit(addr, EngineIO.MemoryType.Output);
                elseif type == "Float"
                    device = EngineIO.MemoryMap.Instance.GetFloat(addr, EngineIO.MemoryType.Output);
                end

                % Use the capValues and checkConflicts if asked
                if capValues
                    if type == "Bool"
                        if values(i)
                            values(i) = 1;
                        else
                            values(i) = 0;
                        end
                    elseif type == "Float"
                        if capRows(i)
                            if values(i) > 10
                                values(i) = 10;
                            elseif values(i) < 0
                                values(i) = 0;
                                %  else % Not needed
                                %  values(i) = values(i);
                            end
                        end
                    else % There are no output DateTimes or others, throw an error
                        error("Unrecognized output type %s for data address %d",type,addr);
                    end
                end

                % Odd row: Disable next value
                % Even row: Disable prev. value
                if checkConflicts
                    % Incompatible bool values
                    if conflictRows(i)
                        if rem(conflictRows(i),2) % == 1
                            addr2 = obj.Special.ConflictOutputs.Address(conflictRows(i)+1);
                            %addr2 = addr2{:,:};
                            device2 = EngineIO.MemoryMap.Instance.GetBit(addr2, EngineIO.MemoryType.Output);
                        else % rem(conflictRows(i),2) == 0
                            addr2 = obj.Special.ConflictOutputs.Address(conflictRows(i)-1);
                            %addr2 = addr2{:,:};
                            device2 = EngineIO.MemoryMap.Instance.GetBit(addr2, EngineIO.MemoryType.Output);
                        end
                        device2.Value = 0;
                    end

                    % Incompatible Bool/Float values
                    if BoolFloatRows(i)
                        if rem(BoolFloatRows(i),2) % == 1, it's a Bool so the other one is Float
                            addr2 = obj.Special.BoolFloatOutputs.Address(BoolFloatRows(i)+1);
                            device2 = EngineIO.MemoryMap.Instance.GetFloat(addr2, EngineIO.MemoryType.Output);
                        else % rem(idx,2) == 0, , it's a Float so the other one is Bool
                            addr2 = obj.Special.BoolFloatOutputs.Address(BoolFloatRows(i)-1);
                            device2 = EngineIO.MemoryMap.Instance.GetBit(addr2, EngineIO.MemoryType.Output);
                        end
                        device2.Value = 0;
                    end

                end

                % Set all values now
                device.Value = values(i);
            end
            
            % Sometimes all other values update correctly except for these
            % Give our model a hand:
            obj.FullData.Value(data.RowID) = values;

            %% Force update if required; values will be read by the events
            if update
                obj.updateHomeIO();
            end
        end

        % Not providing a setValuesFromRowID function, because it has 
        % necessarily to go back to get the to the full row data in order
        % to retrieve DataType, MemoryType and Address.

        function out = estimatePower(obj)
            %estimatePower returns the power consumption estimated via the
            % devices currently active. Does not need Home IO running.
            out = sum(obj.FullData.Power.*obj.FullData.Value);
        end

        function OnTimerCall(obj,~,~)
            %Timer callback if event handlers are available

            %profile resume
            %tim = toc;
            obj.checkHomeIO("action","error");
            obj.updateHomeIO(); % Callback is automatically executed by listener handles
            %disp(toc-tim);
            %profile off
        end

        function OnTimerCallNoListener(obj,~,~)
            %Timer Callback if listener handles are deactivated. Update is
            %   done manually via the readValues method.

            %profile resume
            %tim = toc;
            obj.checkHomeIO("action","error");
            obj.updateHomeIO();
            obj.FullData.Value = obj.readValues();
            %disp(toc-tim);
            %profile off
        end

        function delete(obj)
            %Remove timers and listeners to avoid unnecessary cluttering
            if obj.Config.set_timer
                stop(obj.Comm.t);
                delete(obj.Comm.t);
            end

            if obj.Config.set_listener
                delete(obj.Comm.lh1);
                delete(obj.Comm.lh2);
                delete(obj.Comm.lh3);
            end
            EngineIO.MemoryMap.Instance.Dispose();
        end

        function s = saveobj(obj)
            %Save our object to a class to reconstruct it. Configuration
            % parameters are just enough to accomplish this task.
            s.Config = obj.Config;
        end

    end

    methods (Access = private)

        function changePower10V(obj)
            %changePower10V divides by 10 these outputs that range in the
            %value 0-10V, so that they will consume power proportional to
            %that voltage
            % All of these are Output Floats, VarType == 5
            rows = obj.BaseData.VarType == 5;
            obj.BaseData.Power(rows) = obj.BaseData.Power(rows)/10;
        end

        function OnValuesChanged(obj,varargin)
            % Callback function called by event handlers after updating
            % Home I/O from the update function.

            % varargin{1} is the name of the event, which is useless
            % varargin{2}.MemoriesBit, varargin{2}.MemoriesFloat, varargin{2}.MemoriesDateTime
            % These three are vectors, length specified in varargin{2}.Memories[[TYPE]].Length
            % Direct access, eg, by using varargin(2).MemoriesFloat(i)

            obj.updateFromEvent(varargin{2});
        end

        function updateFromEvent(obj,data)
            %updateFromEvent updates values from the obj.FullData attribute
            %   caught from the events.
           
            % Get MemoriesBit values
            if data.MemoriesBit.Length > 0
                for i=1:data.MemoriesBit.Length
                    % Get data, then get the index
                    datarow = data.MemoriesBit(i);

                    % Below is equivalent to these 2 lines, but faster
                    %rowid = obj.Types.Bools.RowID( ...
                    %    obj.Types.Bools.MemoryType == string(datarow.MemoryType) & ...
                    %    obj.Types.Bools.Address == datarow.Address);
                    %obj.FullData.Value(rowid) = datarow.Value;

                    obj.FullData.Value( obj.Types.Bools.RowID( ...
                        obj.Types.Bools.MemoryType == string(datarow.MemoryType) & ...
                        obj.Types.Bools.Address == datarow.Address) ...
                        ) = datarow.Value;

                end
            end

            if data.MemoriesFloat.Length > 0
                for i=1:data.MemoriesFloat.Length
                    % Get data, then get the index
                    datarow = data.MemoriesFloat(i);

                    % Below is equivalent to these 2 lines, but faster
                    %rowid = obj.Types.Floats.RowID( ...
                    %    obj.Types.Floats.MemoryType == string(datarow.MemoryType) & ...
                    %    obj.Types.Floats.Address == datarow.Address);
                    %obj.FullData.Value(rowid) = datarow.Value;

                    obj.FullData.Value(obj.Types.Floats.RowID( ...
                        obj.Types.Floats.MemoryType == string(datarow.MemoryType) & ...
                        obj.Types.Floats.Address == datarow.Address) ...
                        ) = datarow.Value;
                    
                end
            end

            if data.MemoriesDateTime.Length > 0
                for i=1:data.MemoriesDateTime.Length
                    % Get data, then get the index
                    datarow = data.MemoriesDateTime(i);

                    % Datenum accepts double values only
                    temp = datarow.Value;
                    temp = double([temp.Year temp.Month temp.Day temp.Hour temp.Minute temp.Second+temp.Millisecond/1000]);
                    
                    obj.FullData.Value(obj.Types.DateTimes.RowID( ...
                        obj.Types.DateTimes.MemoryType == string(datarow.MemoryType) & ...
                        obj.Types.DateTimes.Address == datarow.Address) ...
                        ) = datenum(temp(1), temp(2), temp(3), temp(4), temp(5), temp(6));
                end
            end
        end

        function splitData(obj)
            % splitData splits the data in zones (rooms) and other logical
            % categories, to enable ease of usage by the end user.

            %% Split per useful categories

            % Memory Types
            obj.Types.Inputs   = obj.BaseData(obj.BaseData.MemoryType == 'Input',:);
            obj.Types.Outputs  = obj.BaseData(obj.BaseData.MemoryType == 'Output',:);
            obj.Types.Memories = obj.BaseData(obj.BaseData.MemoryType == 'Memory',:);
            
            obj.Types.Bools     = obj.BaseData(obj.BaseData.DataType == 'Bool',:);
            obj.Types.Floats    = obj.BaseData(obj.BaseData.DataType == 'Float',:);
            obj.Types.DateTimes = obj.BaseData(obj.BaseData.DataType == 'DateTime',:);

            obj.Types.InputBools      = obj.BaseData(obj.BaseData.VarType == 1,:);
            obj.Types.InputFloats     = obj.BaseData(obj.BaseData.VarType == 2,:);
            obj.Types.InputDateTimes  = obj.BaseData(obj.BaseData.VarType == 3,:);
            obj.Types.OutputBools     = obj.BaseData(obj.BaseData.VarType == 4,:);
            obj.Types.OutputFloats    = obj.BaseData(obj.BaseData.VarType == 5,:);
            obj.Types.OutputDateTimes = obj.BaseData(obj.BaseData.VarType == 6,:);
            obj.Types.MemoryBools     = obj.BaseData(obj.BaseData.VarType == 7,:);
            obj.Types.MemoryFloats    = obj.BaseData(obj.BaseData.VarType == 8,:);
            obj.Types.MemoryDateTimes = obj.BaseData(obj.BaseData.VarType == 9,:);

            % Zones
            obj.Zones.ZoneA    = obj.BaseData(obj.BaseData.Zone == 'A',:);
            obj.Zones.ZoneB    = obj.BaseData(obj.BaseData.Zone == 'B',:);
            obj.Zones.ZoneC    = obj.BaseData(obj.BaseData.Zone == 'C',:);
            obj.Zones.ZoneD    = obj.BaseData(obj.BaseData.Zone == 'D',:);
            obj.Zones.ZoneE    = obj.BaseData(obj.BaseData.Zone == 'E',:);
            obj.Zones.ZoneF    = obj.BaseData(obj.BaseData.Zone == 'F',:);
            obj.Zones.ZoneG    = obj.BaseData(obj.BaseData.Zone == 'G',:);
            obj.Zones.ZoneH    = obj.BaseData(obj.BaseData.Zone == 'H',:);
            obj.Zones.ZoneI    = obj.BaseData(obj.BaseData.Zone == 'I',:);
            obj.Zones.ZoneJ    = obj.BaseData(obj.BaseData.Zone == 'J',:);
            obj.Zones.ZoneK    = obj.BaseData(obj.BaseData.Zone == 'K',:);
            obj.Zones.ZoneL    = obj.BaseData(obj.BaseData.Zone == 'L',:);
            obj.Zones.ZoneM    = obj.BaseData(obj.BaseData.Zone == 'M',:);
            obj.Zones.ZoneN    = obj.BaseData(obj.BaseData.Zone == 'N',:);
            obj.Zones.ZoneO    = obj.BaseData(obj.BaseData.Zone == 'O',:);
            obj.Zones.ZoneNone = obj.BaseData(obj.BaseData.Zone == '-',:);

            % By object types
            % Input Bools
            obj.Devices.LightSwitches         = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Light Switch") & ~contains(obj.Types.InputBools.Name,"Dimmer"),:);
            obj.Devices.UpDownSwitches        = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Up/Down Switch"),:);
            obj.Devices.LightDimmersUpDown    = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Light Switch Dimmer"),:);
            obj.Devices.DoorDetectors         = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Door Detector"),:);
            obj.Devices.MotionDetectors       = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Motion Detector"),:);
            obj.Devices.BrightnessSensorsBool = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Brightness Sensor"),:);
            obj.Devices.SmokeDetectors        = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Smoke Detector"),:);
            obj.Devices.AlarmKeyPadArmed      = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Alarm Key Pad"),:);
            obj.Devices.GarageDoorSensors     = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Garage Door"),:);
            obj.Devices.EntranceGateSensors   = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Entrance Gate"),:);
            obj.Devices.RemoteButtons         = obj.Types.InputBools(contains(obj.Types.InputBools.Name,"Remote Button"),:);

            % Input Floats
            obj.Devices.BrightnessSensorsFloat = obj.Types.InputFloats(contains(obj.Types.InputFloats.Name,"Brightness Sensor"),:);
            obj.Devices.ThermostatTemperatures = obj.Types.InputFloats(contains(obj.Types.InputFloats.Name,"(Room Temperature)"),:);
            obj.Devices.ThermostatSetPoints    = obj.Types.InputFloats(contains(obj.Types.InputFloats.Name,"(Set Point)"),:);
            obj.Devices.RollerShades           = obj.Types.InputFloats(contains(obj.Types.InputFloats.Name,"Roller Shades"),:);

            % Input DateTime
            obj.Devices.DateAndTimeInput = obj.Types.InputDateTimes(contains(obj.Types.InputDateTimes.Name,"Date and Time"),:);

            % Output Bools
            obj.Devices.LightsBool          = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Lights"),:);
            obj.Devices.RollerShadesUpDown  = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Roller Shades"),:);
            obj.Devices.HeatersBool         = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Heater"),:);
            obj.Devices.Sirens              = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Siren"),:);
            obj.Devices.AlarmKeyPad         = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Alarm Key Pad"),:);
            obj.Devices.GarageDoorOpenClose = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Garage Door"),:);
            obj.Devices.EntranceGate        = obj.Types.OutputBools(contains(obj.Types.OutputBools.Name,"Entrance Gate"),:);

            % Output Floats
            obj.Devices.LightsFloat  = obj.Types.OutputFloats(contains(obj.Types.OutputFloats.Name,"Lights"),:);
            obj.Devices.HeatersFloat = obj.Types.OutputFloats(contains(obj.Types.OutputFloats.Name,"Heater"),:);

            % Output DateTimes
            % Nonexistent

            % Memory Bools
            obj.Devices.DLST = obj.Types.MemoryBools(contains(obj.Types.MemoryBools.Name,"DLST"),:);

            % Memory Floats
            obj.Devices.TimeScale         = obj.Types.MemoryFloats(contains(obj.Types.MemoryFloats.Name,"Time Scale"),:);
            obj.Devices.LatLongitude      = obj.Types.MemoryFloats(contains(obj.Types.MemoryFloats.Name,["Latitude", "Longitude"]),:);
            obj.Devices.EnvironmentValues = obj.Types.MemoryFloats(obj.Types.MemoryFloats.Address >= 132 & obj.Types.MemoryFloats.Address <= 140,:);
            obj.Devices.InstantPower      = obj.Types.MemoryFloats(contains(obj.Types.MemoryFloats.Name,"Instant Power"),:);
            obj.Devices.CurrentPower      = obj.Types.MemoryFloats(contains(obj.Types.MemoryFloats.Name,"Current"),:);
            obj.Devices.LastPower         = obj.Types.MemoryFloats(contains(obj.Types.MemoryFloats.Name,"Last"),:);
            obj.Devices.ZoneTemperatures  = obj.Types.MemoryFloats(obj.Types.MemoryFloats.Zone ~= "-",:);

            % Memory DateTimes
            obj.Devices.DateAndTimeMemory = obj.Types.MemoryDateTimes(contains(obj.Types.MemoryDateTimes.Name,"Date"),:);


            % Other memberships
            obj.Special.InputsNO        = obj.Types.InputBools(obj.Types.InputBools.ContactType == 'NO',:);
            obj.Special.InputsNC        = obj.Types.InputBools(obj.Types.InputBools.ContactType == 'NC',:);
            obj.Special.Inputs10V       = [obj.Devices.BrightnessSensorsFloat; obj.Devices.RollerShades];
            obj.Special.Outputs10V      = [obj.Devices.LightsFloat; obj.Devices.HeatersFloat];

            obj.Special.ConflictInputs   = [obj.Devices.UpDownSwitches; obj.Devices.LightDimmersUpDown];
            obj.Special.ConflictOutputs  = [obj.Devices.RollerShadesUpDown; obj.Devices.GarageDoorOpenClose; obj.Devices.EntranceGate; obj.Devices.AlarmKeyPad];

            % Special.BoolFloatOutputs will save us time if stored
            % alternating the corresponding Bool and Float consecutively
            % Not pretty but useful. TOO SLOW but only runs once
            obj.Special.BoolFloatOutputs = table();

            for i=1:size(obj.Devices.LightsBool)
                obj.Special.BoolFloatOutputs = [obj.Special.BoolFloatOutputs; obj.Devices.LightsBool(i,:); obj.Devices.LightsFloat(i,:)];
            end

            for i=1:size(obj.Devices.HeatersBool)
                obj.Special.BoolFloatOutputs = [obj.Special.BoolFloatOutputs; obj.Devices.HeatersBool(i,:); obj.Devices.HeatersFloat(i,:)];
            end

        end

    end

    methods (Static)

        function connectHomeIO(varargin)
            %Connects this thread to the Engine I/O DLL library

            default_path = strcat(pwd,'\EngineIO.dll');
            p = inputParser;
            p.addOptional('engineio_path',default_path,@mustBeFile);
            p.parse(varargin{:});

            engineio_path = p.Results.engineio_path;

            % Link Engine I/O library
            NET.addAssembly(engineio_path);
        end

        function out = readExcelData(varargin)
            %Read and preprocess all data from the Excel table to get the
            %   array to assign, typically, to obj.BaseData

            %% Parse inputs
            default_data_path     = strcat(pwd,'\homeio_full.xlsx');

            p = inputParser;
            p.addOptional('data_path',default_data_path,@mustBeFile);
            p.parse(varargin{:});

            data_path = p.Results.data_path;

            %% Read and prepare all data from the table (same with path)
            warning('OFF', 'MATLAB:table:ModifiedAndSavedVarnames')
            out = readtable(data_path,'VariableNamingRule',"modify");
            warning('ON', 'MATLAB:table:ModifiedAndSavedVarnames')

            % Set strings to MemoryType, DataType, Zone and ContactType
            % Makes arrays supposedly faster to check than categorical type
            out.MemoryType  = string(out.MemoryType);
            out.DataType    = string(out.DataType);
            out.Zone        = string(out.Zone);
            out.ContactType = string(out.ContactType);
            out.Name        = string(out.Name);      

            % Add VarType to speed array checks (saves string comparisons)
            % Calculate VarType according to MemoryType and DataType
            % VarType = 1 Input Bool
            % VarType = 2 Input Float
            % VarType = 3 Input DateTime
            % VarType = 4 Output Bool
            % VarType = 5 Output Float
            % VarType = 6 Output DateTime
            % VarType = 7 Memory Bool
            % VarType = 8 Memory Float
            % VarType = 9 Memory DateTime

            out.VarType = ...
                1 * (out.MemoryType == 'Input' & out.DataType == 'Bool') + ...
                2 * (out.MemoryType == 'Input' & out.DataType == 'Float') + ...
                3 * (out.MemoryType == 'Input' & out.DataType == 'DateTime') + ...
                4 * (out.MemoryType == 'Output' & out.DataType == 'Bool') + ...
                5 * (out.MemoryType == 'Output' & out.DataType == 'Float') + ...
                6 * (out.MemoryType == 'Output' & out.DataType == 'DateTime') + ...
                7 * (out.MemoryType == 'Memory' & out.DataType == 'Bool') + ...
                8 * (out.MemoryType == 'Memory' & out.DataType == 'Float') + ...
                9 * (out.MemoryType == 'Memory' & out.DataType == 'DateTime');

            out = movevars(out,'VarType','Before','MemoryType');

            % Sort to keep the like variables near one another
            % Mainly affects Outputs, which are really unordered
            out = sortrows(out,{'VarType','Address'},'ascend');

            % Add RowID parameter to make searches faster and less cluttery
            % Calculate RowIDs here if applicable
            for i=1:height(out)
                out.RowID(i) = i;
            end

            out = movevars(out,'RowID','Before','VarType');
        end

        function updateHomeIO()
            %Simply runs the Home I/O command to update the MemoryMap
            EngineIO.MemoryMap.Instance.Update();
        end

        function [Lia, Locb] = checkMember(A,B)
            % A wrapper function of ismember for our table properties 
            % which speeds up comparisons based on RowIDs instead of
            % checking the full rows and saves a lot of time
            [Lia, Locb] = ismember(A.RowID,B.RowID);
        end

        function mustMember(A,B)
            % A wrapper function of mustBeMember for our table properties 
            % which speeds up comparisons based on RowIDs instead of
            % checking the full rows and saves a lot of time
            mustBeMember(A.RowID,B.RowID);
        end

        function obj = loadobj(s)
            %loadobj tries to restore the previous object
            %   No need to test for errors with the isstruct check since 
            %   the constructor usually generates listeners, which are 
            %   non-copyable and must be restored manually (so call
            %   the constructor back with the same arguments)
            engineio_path = s.Config.engineio_path;
            data_path = s.Config.data_path;
            set_timer = s.Config.set_timer;
            set_listener = s.Config.set_listener;
            
            obj = HomeIO('engineio_path',engineio_path,'data_path',data_path,'set_timer',set_timer,'set_listener',set_listener);
        end

    end
end

