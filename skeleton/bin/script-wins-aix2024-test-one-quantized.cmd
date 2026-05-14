yolo_cpu.exe detector test yolohw.names aix2024.cfg aix2024.weights -thresh 0.24 test01.jpg -out_filename test01-det-quantized -quantized -save_params
: yolo_cpu.exe detector test yolohw.names aix2024.cfg aix2024.weights -thresh 0.24 test02.jpg -out_filename test02-det-quantized -quantized -save_params
: yolo_cpu.exe detector test yolohw.names aix2024.cfg aix2024.weights -thresh 0.24 test03.jpg -out_filename test03-det-quantized -quantized -save_params

pause
