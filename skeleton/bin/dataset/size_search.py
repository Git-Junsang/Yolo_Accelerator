import os
import random
import glob
import enum
import numpy as np

current_dir = os.getcwd()

class Object(enum.Enum):
	aunt_jemima_original_syrup = 0
	band_aid_clear_strips = 1
	bumblebee_albacore = 2
	cholula_chipotle_hot_sauce = 3
	crayola_24_crayons = 4
	hersheys_cocoa =5
	honey_bunches_of_oats_honey_roasted = 6
	honey_bunches_of_oats_with_almonds = 7
	hunts_sauce = 8
	listerine_green = 9
	mahatma_rice = 10 
	white_rain_body_wash = 11
	pringles_bbq = 12
	cheeze_it = 13
	hersheys_bar = 14
	redbull = 15
	mom_to_mom_sweet_potato_corn_apple = 16
	a1_steak_sauce = 17
	jif_creamy_peanut_butter = 18
	cinnamon_toast_crunch = 19 
	arm_hammer_baking_soda = 20 
	dr_pepper = 21
	haribo_gold_bears_gummi_candy = 22
	bulls_eye_bbq_sauce_original = 23
	reeses_pieces = 24
	clif_crunch_peanut_butter = 25
	mom_to_mom_butternut_squash_pear = 26
	pop_trarts_strawberry = 27 
	quaker_big_chewy_chocolate_chip = 28 
	spam = 29 
	coffee_mate_french_vanilla = 30
	pepperidge_farm_milk_chocolate_macadamia_cookies = 31
	kitkat_king_size = 32
	snickers = 33
	toblerone_milk_chocolate = 34
	clif_z_bar_chocolate_chip = 35
	nature_valley_crunchy_oats_n_honey = 36 
	ritz_crackers = 37
	palmolive_orange = 38 
	crystal_hot_sauce = 39
	tapatio_hot_sauce = 40
	nabisco_nilla_wafers = 41
	pepperidge_farm_milano_cookies_double_chocolate = 42
	campbells_chicken_noodle_soup = 43
	frappuccino_coffee = 44


####Process

print("object", end="\t")
print("~0.08",end="\t")
print("~0.12",end="\t")
print("~0.16",end="\t")
print("~0.20",end="\t")
print("~0.24",end="\t")
print("~0.28",end="\t")
print("~0.32",end="\t")
print("~0.36",end="\t")
print("~0.4",end="\t")
print("~0.44",end="\t")
print("~0.48",end="\t")
print("0.48~")

for obj in Object:
	list = []
	for f_path in glob.iglob(os.path.join(current_dir, "*.jpg")):
        	title, ext = os.path.splitext(os.path.basename(f_path))
        	list.append(title)      	
	total_cnt = 0
	cnt = np.zeros(12, dtype=float)

	while list:
		name = random.choice(list)
		f = open(name+".txt", "r")
		txtfile = f.readlines()

		for line in txtfile:
			contents = line.split()
			if((int)((float)(contents[0])) == obj.value):	
				total_cnt += 1
				if(float(contents[3])*float(contents[4])<0.0064):
					cnt[0] += 1
				elif(float(contents[3])*float(contents[4])<0.0144):
					cnt[1] += 1
				elif(float(contents[3])*float(contents[4])<0.0256):
					cnt[2] += 1
				elif(float(contents[3])*float(contents[4])<0.04):
					cnt[3] += 1
				elif(float(contents[3])*float(contents[4])<0.0484):
					cnt[4] += 1
				elif(float(contents[3])*float(contents[4])<0.0784):
					cnt[5] += 1
				elif(float(contents[3])*float(contents[4])<0.1024):
					cnt[6] += 1
				elif(float(contents[3])*float(contents[4])<0.1296): 
					cnt[7] += 1
				elif(float(contents[3])*float(contents[4])<0.16): 
					cnt[8] += 1
				elif(float(contents[3])*float(contents[4])<0.1936): 
					cnt[9] += 1	
				elif(float(contents[3])*float(contents[4])<0.2304): 
					cnt[10] += 1				
				else:
					cnt[11] += 1	
		f.close()

		list.remove(name)

	print(obj.name, end="\t")
	if(total_cnt != 0):
		for i in range(12):
			print(format(cnt[i]/total_cnt,"4.2%"),end="\t")
	print()

input("Press Enter to exit...")
