% Extract data from Home I/O
clear

%% Time parameters in real time seconds and fps (frames per second)
time.second = 1;
time.minute = 60;
time.hour   = time.minute*60;
time.day    = time.hour*24;

time.fps          = 60; % From C# Home I/O examples
time.secondframes = time.second*time.fps;
time.minuteframes = time.minute*time.fps;
time.hourframes   = time.hour  *time.fps;
time.dayframes    = time.day   *time.fps;

%% Simulation parameters (sampling and time)
% At 5000x, 1 frame is 83.333 s or 1.38 min (1 day is 17.28 secs approx)
% At  500x, 1 frame is  8.333 s or 0.138 min (1 day is 172 secs approx)
sim_speed = 500; % 1, 50, 500 or 5000
get_one_frame_per_each = 4; % 1 for all frames, 2 to skip half of frames...

% end_time and sample time preferently in simulation times (seconds). 
% Frames can be used but these must be consistent units
end_time = 2*(12*2+1)*time.day; % 2 days * (12 heaters*(on+off)+no heater)
sample_time = 30*time.second; % Manually chosen
% Actual sample time formula: (sim_speed/time.fps) * (get_one_frame_per_each) [simtime per frame * frame skips]

% These are calculated
samples_day = ceil(time.day/sample_time); % Samples in a day
num_samples = ceil(end_time/sample_time); % Total number of simulation samples

% Time in reality to wait for getting a simulation's sample time
sample_time_read = get_one_frame_per_each/time.fps; % = 4/60

% Change rate is calculated in number of samples before changing the experiment 
change_rate = samples_day; % Change rate of 1 day
num_days = ceil(end_time/time.day); % Because this is based on days

%% Home I/O constants and simulation parameters 
m = HomeIO('set_timer',false);

% Here inputs are seen as our control actions and outputs as statuses
% This is reversed from the Home I/O software!
% Actions and measures for identification purposes
% Temperatures extracted from Memories. 

%     Zones B,C,F are excluded for not having heaters
% home_others is reserved to DateTime

% home_inputs  = [m.Devices.HeatersBool]; % Possible but changed to Float for coherence 
% home_outputs = [m.Devices.ZoneTemperatures]; % From Memories, easier to understand

home_inputs  = [m.Devices.HeatersFloat];
home_outputs  = m.Devices.ZoneTemperatures(...
                    ~ismember(m.Devices.ZoneTemperatures.Zone,["B","C","F"]) ,:);
home_disturbs = [m.Devices.EnvironmentValues(1,:); % Air temperature
                m.Devices.BrightnessSensorsFloat(m.Devices.BrightnessSensorsFloat.Zone == "O",:)];
home_others   = [m.Devices.DateAndTimeMemory]; % For representation

home_data = [home_inputs; home_outputs; home_disturbs; home_others]; % 
home_data_rowIDs = home_data.RowID;

% Get the indexes for home data via ismember or m.checkMember
[~,inputs_indexes]   = m.checkMember(home_inputs,home_data);
[~,outputs_indexes]  = m.checkMember(home_outputs,home_data);
[~,disturbs_indexes] = m.checkMember(home_disturbs,home_data);
[~,others_indexes]   = m.checkMember(home_others,home_data);

num_inputs = height(home_inputs);
num_outputs = height(home_outputs);
num_disturbs = height(home_disturbs);
num_data = height(home_data);

%% Prepare inputs so it doesn't run in the loop
% Currently: 2 days for every input one hot encoding (or none hot)

% Getting inputs for 1 day each, then duplicate using kron
inputs = zeros(num_inputs,num_days/2);
for i=1:num_inputs 
    inputs(i,2*i) = 10;
end
inputs = (kron(inputs,ones(1,2)));

%% Prepare variables 
values = zeros(num_data,num_samples);

% Diagnostics: check if done on time and sleep calculations
exec_data = table('Size',[num_samples 4], ...
                  'VariableTypes',{'double','logical','double','double'}, ...
                  'VariableNames',{'TimeElapsed','OnTime','EstimatedSleep','ActualSleep'});

%% Simulation
% Note how few lines are used for simulation.
% There are more code for diagnostics!

tic;
for i=1:num_samples
    t1 = toc;

    % Change values when needed
    if ~mod(i-1,change_rate) % == 0
        % Change heaters
        actions = inputs(:,floor((i-1)/change_rate)+1); % Column of actions
        m.setValues(home_inputs,actions,'update',false,'checkHomeIO',false,'checkConflicts',false);
    end

    % Update now and reflect new values altogether
    m.updateHomeIO();

    % Get values after the interruptions
    values(:,i) = m.getValuesFromRowIDs(home_data_rowIDs);

    % Execution time
    t = (toc-t1);
    exec_data.TimeElapsed(i) = t;
    exec_data.OnTime(i) = t < sample_time_read;

    % Sleep time
    est_sleep = sample_time_read - (toc-t1);
    exec_data.EstimatedSleep(i) = est_sleep;
    t2 = toc;
    pause(est_sleep-0.01) % 0.01 to correct deviations due to clock

    actual_sleep = toc-t2;
    exec_data.ActualSleep(i) = actual_sleep;
end

%% Simulation diagnostics for times (leave commented if not needed)

% Convert datenum to more convenient datetimes
%if exist('others_indexes','var') 
    %times = datetime(values(others_indexes(1),:),"ConvertFrom","datenum")';
    
    % Check for uniformity in the intervals as simulation diagnostics
    % intervals = duration.empty(length(times)-1,0);
    % for i=1:length(times)-1
    %     intervals(i) = times(i+1)-times(i);
    % end
    % intervals = intervals'; % Column form for easier checking 
    % disp(mean(intervals)) % Check for uniformity on samples
%end

%% Remove offsets

values_fix = zeros(size(values)); % To avoid a warning
offsets = zeros(height(home_data),1);
for i=1:height(home_data)
    offsets(i) = min(values(i,:));
    values_fix(i,:) = values(i,:) - offsets(i);
end

%% Perform system identification

% For system identification without deoffseting (not reccommended)
% inputs_sysid  = [values(inputs_indexes,:)', values(disturbs_indexes,:)']; % Control inputs + disturbances
% outputs_sysid = values(outputs_indexes,:)';                              % Room temperature

inputs_sysid  = [values_fix(inputs_indexes,:)', values_fix(disturbs_indexes,:)']; % Control inputs + disturbances
outputs_sysid = values_fix(outputs_indexes,:)';                                   % Room temperatures

mydata = iddata(outputs_sysid,inputs_sysid,sample_time);
ss1 = n4sid(mydata, num_outputs, 'Form', 'canonical'); % Takes some time fitting

% Checks
% figure,compare(mydata,ss1);

%% Save results
clear m
save results_new_ident_shipped