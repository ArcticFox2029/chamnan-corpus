# Documentation ABOUT merge conflicts

When git cannot merge, it writes `<<<<<<< HEAD` above your version and `>>>>>>> branch`
below theirs. A detector that matches those strings anywhere flags this file, which is
correct prose explaining the thing it is being mistaken for.
