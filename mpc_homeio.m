%% Clear previous data and load & prepare needed variables
clear all
close all
yalmip('clear')
clc

    % Specific values can be extracted, but no need
    load identification_values.mat ss1 offsets num_inputs...
        num_outputs num_disturbs sample_time_read

    % We need to trim the "others" values from the offset
    offsets = offsets(1:num_inputs+num_outputs+num_disturbs);

%% Simulation parameters
% Simulation length (in number of points: so end time is SimLength*Ts)
SimLength=24*60*2; % number of minutes in a day x2 (30 secs)

%% Load system data:

% Our model: x = A*x + Bu*u + Bd*d;
A = ss1.A;
nx = size(A,1); % A is square so doesn't mind

% Extract Bu (actions), Bd (disturbances) from B matrix
Bu = ss1.B(:,1:num_inputs);
Bd = ss1.B(:,num_inputs+1:end);

nu = size(Bu,2);
nd = size(Bd,2);

% Sample time (30s from the mat file unless changed in upstream mat file)
% x500 speed: 1/3 frames equals 25s; 1/4 frames equals 33.33s
% 30s are enforced because it's not that big of a change.
Ts = ss1.Ts; 

% Constraints: 
xmin = -offsets(1+num_inputs:end-num_disturbs); % Absolute zero from offsets values (K)
umin = 0;
umax = 10;

%% Load home data
m = HomeIO('set_timer',false);
home_actions      = m.Devices.HeatersFloat;
home_temperatures = m.Devices.ZoneTemperatures; % But scrap the unusable ones
home_temperatures = home_temperatures((home_temperatures.Zone ~= "B" & home_temperatures.Zone ~= "C" & home_temperatures.Zone ~= "F"),:);
home_disturbs     = [m.Devices.EnvironmentValues(1,:); 
                     m.Devices.BrightnessSensorsFloat(m.Devices.BrightnessSensorsFloat.Zone == "O",:)];
home_others       = [m.Devices.InstantPower;
                     m.Devices.DateAndTimeMemory;];

% home_acts_ids     = home_actions.RowID;
% home_temps_ids    = home_temperatures.RowID;v
% home_dist_ids     = home_disturbs.RowID;
% home_other_ids    = home_others.RowID;

% Read/write by using just row IDs since it's faster
home_reads  = [home_temperatures; home_disturbs; home_others];
home_writes = [home_actions];

[~, home_actions_indexes]      = ismember(home_actions,home_writes);

[~, home_temperatures_indexes] = ismember(home_temperatures,home_reads);
[~, home_disturbs_indexes]     = ismember(home_disturbs,home_reads);
[~, home_others_indexes]       = ismember(home_others,home_reads);

home_reads_rowIDs = home_reads.RowID;
%home_writes_rowIDs = home_writes.RowID;


%% Prepare MPC controller
% Objective function for controller: 
% sum Ql*x+ Rl*u across control horizon
% Q = error penalizations. Currently it's the same for every entry.
% R = action penalizations. Currently deactivated.
% incR = limit in absolute rate of change of actions. The higher the more penalized.
Q = eye(size(A,1));
R = 0.001*eye(size(Bu,2));
incR = 0;
diffR = 10;

% Prediction horizon
Np = 30;

% reference
ref = 10*ones(nx,1); % Reference: heating 10 º C each room

%% Prepare YALMIP's optimizer structure
% optimizer works better for closed-loop systems

% Even if some values are known a priori, defining them as sdpvars works
% best defining initial values as decision variables
x = sdpvar(repmat(nx,1,Np+1),repmat(1,1,Np+1)); % nx statuses in column across Np predictions + current
u = sdpvar(repmat(nu,1,Np),  repmat(1,1,Np));   % nu actions in column across Np predictions

d = sdpvar(2,1); % Use current disturbance as we don't know the "future"
last_u = sdpvar(nu,1); % Last actions

% Objective and constraints
%objective = 0;
objective = (last_u-u{1})'*incR*(last_u-u{1}); % Rate of change of incR as cost
constraints = [-diffR <= last_u-u{1} <= diffR]; % incR limit on each step (may cause infeasibilities)
%constraints = [];

for k = 1:Np
    objective = objective + (x{k}-ref)'*Q*(x{k}-ref) + u{k}'*R*u{k}; % Usual cost function for a MPC
    constraints = [constraints, x{k+1} == A*x{k}+Bu*u{k}+Bd*d];      % Subject to natural system evolution x = Ax + Bu + Bd*d
    constraints = [constraints, umin <= u{k}   <= umax];             % Subject to actuator limits
    constraints = [constraints, xmin <= x{k+1}];                     % Subject to temperatures over absolute zero
    if k > 1
        objective = objective + (u{k-1}-u{k})'*incR*(u{k-1}-u{k});
        constraints = [constraints, -diffR <= u{k-1}-u{k} <= diffR];                     % Subject to temperatures over absolute zero
    end
end
objective = objective + (x{Np+1}-ref)'*(x{Np+1}-ref);                % Terminal cost

% Inputs and outputs
params_input = {x{1},d,last_u}; % Add ref in a future for dynamic ref!
sol_output   = {[u{:}], [x{:}]};

% Options
opt = sdpsettings();
opt = sdpsettings(opt,'solver','gurobi');
opt = sdpsettings(opt,'verbose',0);

controller = optimizer(constraints, objective, opt, params_input,sol_output);

%% History matrices, initial values, diagnostics
% Nothe that these new x,d overwrite old ones

% Read from home
m.updateHomeIO()
home_values = m.getValuesFromRowIDs(home_reads_rowIDs);

% We reserve x, d non subscript for deoffseted values
x_real = home_values(home_temperatures_indexes);
d_real = home_values(home_disturbs_indexes);
W_cons = home_values(home_others_indexes(1));
time  = home_values(home_others_indexes(2));

x = x_real - offsets(1+nu   :nu+nx);
d = d_real - offsets(1+nu+nx:nu+nx+nd);

umpc = zeros(nu,1);  % Last action

if any(isnan(x(:)))
    error("NaN values on results given by Home I/O! Is it running?")
end

Xhist = [x];
Dhist = [d];
Thist = [time];
Whist = [W_cons];
Uhist = [umpc];

Xrealhist = [x_real];
Drealhist = [d_real];

% Check if done on time, comment for real identification
run_data = table('Size',[SimLength 4], ...
                 'VariableTypes',{'double','logical','double','double'}, ...
                 'VariableNames',{'TimeElapsed','OnTime','EstimatedSleep','ActualSleep'});

%% Controlled system simulation

tic
for k=1:SimLength
    t1 = toc;

    % Display how much we are done here
    if rem(k,100)==0
        %disp(k),disp(SimLength)
        fprintf("%d/%d; Elapsed time is %f seconds.\n",k,SimLength,t1);
    end
    
    % x,d,umpc come from before loop and previous iteration, then solve
    inputs = {x,d,umpc};
    [solutions,diagnostics] = controller{inputs};
    if diagnostics == 1
        fprintf("%d/%d\n",k,SimLength)
        error('The problem is infeasible or unbounded!');
    end   
    
    % Fetch results
    U = solutions{1};
    umpc = U(:,1);
    umpc = round(umpc,2); % Unneeded but gives some reality
    X = solutions{2};

    % Stepping the system in case Home I/O was not present
    % x = A*x + Bu*umpc +Bd*d;

    % Update home via home methods
    m.setValues(home_writes,umpc,'update',false,'checkHomeIO',false,'checkConflicts',false);
    m.updateHomeIO()
    home_values = m.getValuesFromRowIDs(home_reads_rowIDs);

    % We reserve x, d non subscript for deoffseted values
    x_real = home_values(home_temperatures_indexes);
    d_real = home_values(home_disturbs_indexes);
    W_cons = home_values(home_others_indexes(1));
    t_ini  = home_values(home_others_indexes(2));

    x = x_real - offsets(1+nu   :nu+nx);
    d = d_real - offsets(1+nu+nx:nu+nx+nd);

    if any(isnan(x(:)))
        error("NaN values on results given by Home I/O! Is it running?")
    end
    
    % Save status and actions histories for plotting
    Xhist = [Xhist x];
    Dhist = [Dhist d];
    Thist = [Thist time];
    Whist = [Whist W_cons];
    Uhist = [Uhist umpc];

    Xrealhist = [Xrealhist x_real];
    Drealhist = [Drealhist d_real];

    % Get diagnostics 
    % Execution time
    t = (toc-t1);
    run_data.TimeElapsed(k) = t;
    run_data.OnTime(k) = t < sample_time_read;

    % Sleep time
    est_sleep = sample_time_read - (toc-t1);
    run_data.EstimatedSleep(k) = est_sleep;
    t2 = toc;
    pause(est_sleep-0.01) % 0.01 to correct deviations due to clock

    actual_sleep = toc-t2;
    run_data.ActualSleep(k) = actual_sleep;

end
toc

%% Show results
xticks = 0.5*minutes(1:length(Xhist));

figure
ax1 = subplot(2,2,1);
stairs(xticks,Xhist(1:5,:)','LineWidth',2);
legend
legend("A","D","E","G","H")
%legend(home_outputs.Zone(1:7))
grid on
title("Increment room temperatures A-D-E-G-H")

ax2 = subplot(2,2,2);
stairs(xticks,Xhist(6:end,:)','LineWidth',2);
legend
%legend(home_outputs.Zone(8:end))
legend("I","J","K","L","M","N")
grid on
title("Increment Room temperatures I-N")

linkaxes([ax1 ax2],'xy')

ax3 = subplot(2,2,3);
stairs(xticks,Uhist(1:6,:)','LineWidth',2);
%legend(home_inputs.Zone(1:5))
legend("A","D","E","G1","G2","H")
grid on
title("Control signal heaters A-D-E-G1-G2-H")

ax4 = subplot(2,2,4);
stairs(xticks,Uhist(7:end,:)','LineWidth',2);
%legend(home_inputs.Zone(6:end))
legend("I","J","K","L","M","N")
grid on
title("Control signal heaters I-J-K-L-M-N")

linkaxes([ax3 ax4],'xy')

%% Save results

% sdpvars have traceability and cannot be saved without warnings
% Clear the home too
yalmip("clear")
clear m controller x u d last_u objective constraints ...
    params_input sol_output inputs solutions diagnostics U X

save result_mpc_homeio