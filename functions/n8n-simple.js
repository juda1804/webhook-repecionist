// COPIA Y PEGA ESTO EN TU NODO CODE DE N8N:

// Obtener el mensaje del input
var message = $input.item.json.message || $input.item.json.text || $input.item.json.content || '';

// Si no hay mensaje, retornar error
if (!message) {
    return {
        json: {
            error: 'No se encontró mensaje para procesar',
            formatted_message: '',
            success: false
        }
    };
}

// Extraer autor antes de limpiar
var authorMatch = message.match(/--\s*([^\n]+)/);
var author = authorMatch ? authorMatch[1].trim() : null;

// Limpiar el mensaje eliminando contenido de YouTube
var cleaned = message
    // Eliminar links de YouTube
    .replace(/https?:\/\/[^\s]*youtu[^\s]*/gi, '')
    .replace(/https?:\/\/[^\s]*youtube[^\s]*/gi, '')
    // Eliminar unsubscribe
    .replace(/unsubscribe\s+link:.*$/gmi, '')
    .replace(/.*action_unsubscribe.*$/gmi, '')
    .replace(/.*email_unsubscribe.*$/gmi, '')
    // Eliminar copyright
    .replace(/©.*youtube.*$/gmi, '')
    .replace(/.*youtube.*llc.*$/gmi, '')
    .replace(/.*cherry\s+ave.*$/gmi, '')
    // Eliminar separadores
    .replace(/^---+$/gm, '')
    // Convertir <br/> a saltos de línea
    .replace(/<br\s*\/?>/gi, '\n')
    // Limpiar múltiples saltos de línea
    .replace(/\n\s*\n\s*\n/g, '\n\n')
    // Eliminar espacios al final
    .replace(/[ \t]+$/gm, '')
    // Eliminar líneas vacías
    .replace(/^\s*$/gm, '')
    // Eliminar espacios múltiples
    .replace(/  +/g, ' ')
    .trim();

// Agregar autor si existe
if (author && !cleaned.includes('-- ' + author)) {
    cleaned += '\n\n-- ' + author;
}

// Retornar resultado
return {
    json: {
        formatted_message: cleaned,
        original_message: message,
        success: true,
        compression_ratio: Math.round((1 - cleaned.length / message.length) * 100),
        author: author
    }
}; 