class_name Words
## Common-word pool for zombie labels, bucketed by length. Curated so words are quick to
## read at 640x360 and never obscure. pick() avoids first letters already in use.

const POOL := {
	3: ["cat","dog","run","red","sun","box","cup","hat","key","map","pen","bus","car","egg","fox","gum","ice","jam","lip","mud","net","oak","pig","rat","saw","tin","van","web","yak","zip","axe","bat","cow","dig","elk","fan","gap","hut","ink","jug","kid","log","mop","nut","owl","pot","rug","sky","toy","urn","wax","yam","zoo","bag","cap","den","fig","gem","hop","jet","lid","mat","nap","pad","rib","sap","tap","vet","wig"],
	4: ["bell","bird","boat","book","cake","coin","door","duck","fish","fork","gate","gold","hand","hill","iron","jump","kite","lamp","leaf","lock","milk","moon","nail","nest","oven","park","path","rain","ring","road","rock","rope","salt","sand","ship","shoe","snow","soap","song","star","tent","tree","wall","wave","wind","wolf","wood","yard","bolt","cave","desk","drum","flag","frog","glue","hook","jeep","knot","lime","mask","mint","nose","palm","pipe","quiz","rust","silk","tank","vest","worm","zone"],
	5: ["apple","bread","brick","candy","chair","cloud","crane","dance","eagle","fence","flame","ghost","grape","house","juice","knife","lemon","light","mango","metal","music","night","ocean","onion","paint","paper","piano","pizza","plant","queen","radio","river","robot","salad","sheep","shell","smoke","snake","spoon","stone","storm","sugar","table","tiger","towel","train","truck","water","wheel","whale","zebra","anvil","bacon","cabin","dodge","elbow","fudge","glove","hatch","igloo","jelly","kayak","ladle","medal","noodle","organ","pearl","quilt","raven","siren","toast","vapor","wagon","yacht"],
	6: ["anchor","basket","bottle","bridge","bucket","button","camera","candle","carrot","castle","cheese","cherry","circle","coffee","cookie","dragon","engine","flower","forest","garden","guitar","hammer","helmet","island","jacket","jungle","kitten","ladder","lizard","magnet","marble","mirror","monkey","needle","orange","parrot","pencil","pepper","pillow","planet","pocket","potato","puzzle","rabbit","rocket","saddle","school","shovel","silver","spider","street","sunset","teapot","thread","ticket","tomato","turtle","valley","violin","walnut","window","winter","yellow","zipper"],
	7: ["balloon","bicycle","blanket","cabbage","cactus","chicken","chimney","compass","country","crystal","diamond","dolphin","feather","freezer","giraffe","harvest","highway","jasmine","kingdom","lantern","library","machine","mailbox","monster","morning","mustard","necktie","octopus","pancake","penguin","pumpkin","raccoon","rainbow","sandbox","scooter","shelter","speaker","station","teacher","thunder","trumpet","umbrella","vulture","walrus","whistle","zombie"],
	8: ["airplane","backpack","baseball","birthday","broccoli","calendar","cardinal","cucumber","daffodil","doorbell","elephant","envelope","firework","football","hedgehog","hospital","kangaroo","keyboard","lemonade","mosquito","mountain","notebook","pineapple","reindeer","sandwich","scissors","seashell","skeleton","snowball","squirrel","suitcase","sunshine","telephone","treasure","umbrella","volcano","waterfall","wildfire"],
	10: ["basketball","blackboard","chandelier","dishwasher","flashlight","grasshopper","helicopter","lighthouse","motorcycle","paintbrush","skateboard","strawberry","sunflower","toothbrush","typewriter","watermelon","wheelbarrow"],
	12: ["thunderstorm","refrigerator","cheeseburger","kaleidoscope","hippopotamus","screwdriver","caterpillar","spreadsheet","quarterback","rollercoaster","photographer","dragonfruit"],
}


static func pick(min_len: int, max_len: int, used_first_letters: Dictionary, rng: RandomNumberGenerator) -> String:
	var lengths: Array[int] = []
	for L in POOL.keys():
		if L >= min_len and L <= max_len:
			lengths.append(L)
	if lengths.is_empty():
		lengths.append(5)
	for attempt in 40:
		var L: int = lengths[rng.randi_range(0, lengths.size() - 1)]
		var arr: Array = POOL[L]
		var w: String = arr[rng.randi_range(0, arr.size() - 1)]
		if not used_first_letters.has(w[0]):
			return w
	var L2: int = lengths[0]
	return POOL[L2][rng.randi_range(0, POOL[L2].size() - 1)]
