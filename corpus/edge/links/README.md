# Links that are not files

`loop-a` and `loop-b` point at each other. A walker that follows symlinks never leaves
them. `dangling` points at nothing. `to-the-root` points at the repository itself, so a
follower walks the whole corpus again at every depth.
