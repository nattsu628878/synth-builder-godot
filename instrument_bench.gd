extends SceneTree
func _init():
	var os := []
	var fs := []
	var ls := []
	var rs := []
	var mods := []
	for i in 8:
		os.append({"id": "o%d" % i, "wave": i % 3, "gain": 0.1, "transpose": 0.0})
		fs.append({"id": "f%d" % i, "cutoff": 1000.0 + i * 300, "enabled": true})
		ls.append({"id": "l%d" % i, "rate": 0.5 + i, "depth": 0.1})
		for j in 8:
			rs.append({"from": "o%d" % i, "to": "f%d" % j})
			mods.append({"id": "m%d_%d" % [i,j], "source": "l%d" % i, "target": "f%d" % j, "param": "cutoff", "amount": 0.1})
		for j in range(i+1,8): rs.append({"from": "f%d" % i, "to": "f%d" % j})
		rs.append({"from": "f%d" % i, "to": "output"})
	var s = ClassDB.instantiate("InstrumentSynthRs")
	print("valid=",s.configure_graph(os,fs,rs,ls,mods,0.2))
	for i in 8: s.note_on(48+i,0.5)
	var begin = Time.get_ticks_usec()
	s.render(4096)
	print("DENSE: ms=", (Time.get_ticks_usec()-begin)/1000.0," budget=92.88ms")
	quit()
