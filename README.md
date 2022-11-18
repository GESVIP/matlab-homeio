# matlab-homeio
A simple framework for working with MATLAB and Home I/O

This provides with a simple framework for using MATLAB in conjunction to Home I/O, that works out of the box. This allows the user to easily control the home and its devices without needing to work with the API via MATLAB scripts and/or command line, and offers a number of tools to simplify and improve user experience. Please refer to the examples for basic usage. The code is extensively documented and users are invited to suggest new features, collaborate and/or help improving the code. A more extensive documentation will be provided in case this note and the in-code documentation is not sufficient.

Developed and tested on Home I/O v1.7.1 (latest as of Nov 2022) and MATLAB R2021b. It has not been tested, but it is expected to work in later versions of both softwares.

### What's included?
Here is included the full framework along with required `EngineIO.dll` DLL and Excel file to make it work, a couple examples with relevant data output and control result of the MPC, and a save data in case you don't want to set everything in External mode by yourself.

Please note that results depend strongly on environmental conditions (latitude, longitude, time of the day and year, air temperature, cloudiness, humidity and windiness, configurable by the user). The identification and/or control results will strongly vary with these variables.

### Current limitations
The access to the API from MATLAB is really slow. Managing 338 devices (as shown in the Excel file) with a slow API forces the development to come with a compromise when it comes to capture every frame from Home I/O. You can either consider using a slower simulation speed and capture one in each X frames (and give processing time for other computational needs), update only the values you are interested in (disable listener handlers and send a partial table to the *getData* method so you will update only a small amount of devices), or even reflect upon if you really need that many data at that speed in a simulation where device functioning cannot go wrong. In case everything fails, you might want to use a shorter version of the Excel file, which is not recommended. 

### Not included 
Please bring your own:
* MATLAB software installation: https://www.mathworks.com/
* Home I/O software installation: https://realgames.co/home-io
* PC with enough specs to run both these softwares.

### Original authors
Please cite the original authors of this idea:
* Javier Jiménez Sicardo (jaBote), corresponding author of this framework at jjsicardo [at the domain] us.es
* Elena Mª Mosquera Guerrero (elemosgue)
* José Mª Maestre Torreblanca (pepemaestre)

A scientific publication is underway.
