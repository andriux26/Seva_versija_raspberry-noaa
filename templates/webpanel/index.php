<?php
// Nurodykite katalogo kelia
include_once('header.php');

$audioDirectory = 'audio/'; // Pakeiskite i savo katalogo pavadinima

// Funkcija patikrina, ar failas yra garso formatas
function isAudioFile($filename) {
    $allowedExtensions = ['mp3', 'wav', 'ogg', 'flac', 'aac'];
    $fileExtension = pathinfo($filename, PATHINFO_EXTENSION);
    return in_array(strtolower($fileExtension), $allowedExtensions);
}

// Tikriname, ar katalogas egzistuoja
if (is_dir($audioDirectory)) {
    // Nuskaitykite katalogo turini
    $files = scandir($audioDirectory);

    // Filtruojame tik garso failus
    $audioFiles = array_filter($files, function($file) use ($audioDirectory) {
        return isAudioFile($file) && is_file($audioDirectory . $file);
    });

    // Atvaizduojame garso failus
    if (!empty($audioFiles)) {
        echo "<h1></h1>";
        echo "<ul>";
        foreach ($audioFiles as $file) {
            echo "<li><a href='$audioDirectory$file' target='_blank'>$file</a></li>";
        }
        echo "</ul>";
    } else {
        echo "<p>Kataloge nera garso failu.</p>";
    }
} else {
    echo "<p>Katalogas nerastas: $audioDirectory</p>";
}
include_once("footer.php") 
?>
