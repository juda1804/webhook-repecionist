// Función compatible con n8n para formatear mensajes eliminando contenido de YouTube
function formatMessageForN8N(message) {
    // Validación básica
    if (!message || typeof message !== 'string') {
        return {
            success: false,
            error: 'Mensaje inválido',
            formattedMessage: '',
            originalLength: 0,
            finalLength: 0,
            compressionRatio: 0
        };
    }

    try {
        // Normalizar saltos de línea
        var cleanMessage = message.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
        
        // Extraer autor (patrón: -- NombreAutor)
        var authorMatch = cleanMessage.match(/--\s*([^\n]+)/);
        var author = authorMatch ? authorMatch[1].trim() : null;
        
        // Eliminar contenido de YouTube usando regex
        var withoutYoutube = cleanMessage
            // Eliminar links de YouTube
            .replace(/https?:\/\/[^\s]*youtu[^\s]*/gi, '')
            .replace(/https?:\/\/[^\s]*youtube[^\s]*/gi, '')
            // Eliminar información de unsubscribe
            .replace(/unsubscribe\s+link:.*$/gmi, '')
            .replace(/.*action_unsubscribe.*$/gmi, '')
            .replace(/.*email_unsubscribe.*$/gmi, '')
            // Eliminar copyright de YouTube
            .replace(/©.*youtube.*$/gmi, '')
            .replace(/.*youtube.*llc.*$/gmi, '')
            .replace(/.*cherry\s+ave.*san\s+bruno.*$/gmi, '');
        
        // Limpiar contenido
        var cleaned = withoutYoutube
            // Normalizar <br/> tags
            .replace(/<br\s*\/?>/gi, '\n')
            // Eliminar múltiples saltos de línea
            .replace(/\n\s*\n\s*\n/g, '\n\n')
            // Eliminar espacios al final de líneas
            .replace(/[ \t]+$/gm, '')
            // Eliminar líneas vacías
            .replace(/^\s*$/gm, '')
            // Limpiar espacios múltiples
            .replace(/  +/g, ' ')
            // Eliminar separadores de YouTube
            .replace(/^---+$/gm, '')
            .trim();
        
        // Reconstruir mensaje final
        var finalMessage = cleaned;
        if (author && !finalMessage.includes('-- ' + author)) {
            finalMessage += '\n\n-- ' + author;
        }
        
        // Limpiar resultado final
        finalMessage = finalMessage
            .replace(/\n\s*\n\s*\n/g, '\n\n')
            .trim();
        
        return {
            success: true,
            formattedMessage: finalMessage,
            originalLength: message.length,
            finalLength: finalMessage.length,
            compressionRatio: Math.round((1 - finalMessage.length / message.length) * 100),
            author: author
        };
        
    } catch (error) {
        return {
            success: false,
            error: 'Error al formatear: ' + error.message,
            formattedMessage: '',
            originalLength: message.length,
            finalLength: 0,
            compressionRatio: 0
        };
    }
}

// Para usar en n8n, copia solo esta parte:
var inputMessage = $input.item.json.message || $input.item.json.text || $input.item.json.content;
var result = formatMessageForN8N(inputMessage);

return {
    json: {
        original_message: inputMessage,
        formatted_message: result.formattedMessage,
        success: result.success,
        metadata: {
            original_length: result.originalLength,
            final_length: result.finalLength,
            compression_ratio: result.compressionRatio,
            author: result.author,
            error: result.error || null
        }
    }
}; 