# Parallel/Parametric Job Board Framework (mpjobs)

OpenSeesMP provides basic MPI message-passing commands, which can be used to run parametric studies in parallel. 
The mpjobs package utilizes the OpenSeesMP commands to provide an abstract framework for running parametric studies in series and parallel. 
The framework eliminates the need to deal directly with the message passing commands, and additionally formalizes and organizes the parametric study in a way that supports save-state functionality, allowing the analyst to revisit a study and analyze it further.

To run parametric studies in parallel, one must either compile the OpenSeesMP version of [OpenSees](https://github.com/OpenSees/OpenSees), or install [OpenSeesMPI](https://github.com/ambaker1/OpenSeesMPI).

Full documentation [here](https://raw.githubusercontent.com/ambaker1/mpjobs/main/doc/mpjobs.pdf).
 
## Installation
This package is a Tin package. Tin makes installing Tcl packages easy, and is available [here](https://github.com/ambaker1/Tin).

After installing Tin, either download the latest release of flytrap and run "install.tcl", or simply run the following script in a Tcl interpreter:
```tcl
package require tin 0.4.5
tin add -auto mpjobs https://github.com/ambaker1/mpjobs 0.1-
tin install mpjobs
```
