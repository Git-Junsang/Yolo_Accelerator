//=========================================================================
// UNIX
//=========================================================================
// Generate directories for the dataset
After decompressing the zip file, you can use the following commands:
	cd skeleton				// Direct to the code folder	
	make			        // Compile the code
	cd bin/dataset		    // Go to the bin/dataset/
	python make_list_cur.py	// Update the directories for test images

Run the code	
	cd ..				    						// Go to bin/
	sh script-unix-aix2024-test-all.sh				// Full-Precision: 	Do inference on all test images, and calculate mAP
	sh script-unix-aix2024-test-all-quantized.sh	// Quantization: 	Do inference on all test images, and calculate mAP 
	
	// You can test one image 
	sh script-unix-aix2024-test-one.sh				// Full-Precision: 	Do inference on ONE image
	sh script-unix-aix2024-test-one-quantized.sh	// Quantization: 	Do inference on ONE image

//=========================================================================
//Windows
//=========================================================================
Requirments: 
	+ Install Visual Studio as the Installation Guide
	+ Install Python

After decompressing the zip file, you can use the following commands:
- Go to skeleton
NOTE**: The code is tested with Visual Studion 2019. However, it should work well with other versions. 
	If there is a version conflict, 
		1. Remove yolo_cpu.sln
		2. Double click to yolo_cpu.vcxproj to make a new project with your VS version


NOTE**: Assume your code is located at C:\skeleton 
Open your Windows Terminal
	cd C:\skeleton\bin\dataset	// Go to the bin/dataset/
	python make_list_cur.py		// Update the directories for test images
	cd ..				    	// Go to bin/

Run the code	
	cd ..				    					// Go to bin/
	script-wins-aix2024-test-all.cmd			// Full-Precision: 	Do inference on all test images, and calculate mAP
	script-wins-aix2024-test-all-quantized.cmd	// Quantization: 	Do inference on all test images, and calculate mAP 
	
	// You can test on one image 
	script-wins-aix2024-test-one.cmd			// Full-Precision: 	Do inference on ONE image
	script-wins-aix2024-test-one-quantized.cmd	// Quantization: 	Do inference on ONE image
