# Parallel/Parametric Job Board Framework (mpjobs)

OpenSeesMP provides basic MPI message-passing commands, which can be used to run parametric studies in parallel. 
The "mpjobs" package utilizes the OpenSeesMP commands to provide an abstract framework for running parametric studies in series and parallel, eliminating the need to deal directly with the message passing commands.
Additionally, "mpjobs" formalizes and organizes the parametric study in a way that supports save-state functionality, allowing the analyst to revisit a study and analyze it further.

To run parametric studies in parallel, one must either compile the OpenSeesMP version of [OpenSees](https://github.com/OpenSees/OpenSees), or install [OpenSeesMPI](https://github.com/ambaker1/OpenSeesMPI).

Full documentation [here](https://raw.githubusercontent.com/ambaker1/mpjobs/main/doc/mpjobs.pdf).
 
## Installation
This package is a Tin package. Tin makes installing Tcl packages easy, and is available [here](https://github.com/ambaker1/Tin).
After installing Tin, simply include the following in your script to install "mpjobs":
```tcl
package require tin 0.4.6
tin install mpjobs
```
