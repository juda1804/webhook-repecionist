/**
 * Formateador genérico de mensajes que elimina contenido relacionado con YouTube
 * @param {string} message - El mensaje original a formatear
 * @returns {object} - Objeto con el mensaje formateado y metadatos
 */
function formatMessage(message) {
    if (!message || typeof message !== 'string') {
        return {
            success: false,
            error: 'Mensaje inválido',
            formattedMessage: '',
            metadata: {}
        };
    }

    try {
        // Normalizar saltos de línea
        let cleanMessage = message.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
        
        // Extraer autor si existe (patrón: -- NombreAutor)
        const authorMatch = cleanMessage.match(/--\s*([^\n]+)/);
        const author = authorMatch ? authorMatch[1].trim() : null;
        
        // Dividir el mensaje en secciones para procesamiento
        const sections = cleanMessage.split(/(?=--)|(?=https?:\/\/)|(?=Unsubscribe)|(?=©)/);
        
        let mainContent = '';
        let youtubeLinksRemoved = 0;
        
        for (const section of sections) {
            const trimmedSection = section.trim();
            
            // Saltar secciones vacías
            if (!trimmedSection) continue;
            
            // Eliminar links de YouTube
            if (isYouTubeLink(trimmedSection)) {
                youtubeLinksRemoved++;
                continue;
            }
            
            // Eliminar información de unsubscribe
            if (isUnsubscribeInfo(trimmedSection)) {
                continue;
            }
            
            // Eliminar información de copyright de YouTube
            if (isYouTubeCopyright(trimmedSection)) {
                continue;
            }
            
            // Si es la firma del autor, agregarla por separado
            if (trimmedSection.startsWith('--')) {
                continue; // Ya la extraímos arriba
            }
            
            // Agregar contenido principal
            if (isMainContent(trimmedSection)) {
                mainContent += trimmedSection + '\n';
            }
        }
        
        // Limpiar y formatear el contenido principal
        const formattedContent = cleanMainContent(mainContent);
        
        // Construir mensaje final
        let finalMessage = formattedContent;
        if (author) {
            finalMessage += `\n\n-- ${author}`;
        }
        
        return {
            success: true,
            formattedMessage: finalMessage.trim(),
            metadata: {
                originalLength: message.length,
                finalLength: finalMessage.trim().length,
                author: author,
                youtubeLinksRemoved: youtubeLinksRemoved,
                compressionRatio: Math.round((1 - finalMessage.trim().length / message.length) * 100)
            }
        };
        
    } catch (error) {
        return {
            success: false,
            error: `Error al formatear mensaje: ${error.message}`,
            formattedMessage: '',
            metadata: {}
        };
    }
}

/**
 * Detecta si una sección es un link de YouTube
 */
function isYouTubeLink(text) {
    const youtubePatterns = [
        /youtu\.be/i,
        /youtube\.com/i,
        /^https?:\/\/.*youtu/i
    ];
    
    return youtubePatterns.some(pattern => pattern.test(text));
}

/**
 * Detecta si una sección contiene información de unsubscribe
 */
function isUnsubscribeInfo(text) {
    const unsubscribePatterns = [
        /unsubscribe\s+link/i,
        /action_unsubscribe/i,
        /email_unsubscribe/i
    ];
    
    return unsubscribePatterns.some(pattern => pattern.test(text));
}

/**
 * Detecta si una sección contiene copyright de YouTube
 */
function isYouTubeCopyright(text) {
    const copyrightPatterns = [
        /©.*youtube/i,
        /youtube.*llc/i,
        /cherry\s+ave.*san\s+bruno/i
    ];
    
    return copyrightPatterns.some(pattern => pattern.test(text));
}

/**
 * Detecta si una sección es contenido principal válido
 */
function isMainContent(text) {
    // Ignorar secciones muy cortas que solo contienen espacios o caracteres especiales
    if (text.length < 3) return false;
    
    // Ignorar secciones que solo contienen URLs
    if (/^https?:\/\//.test(text.trim())) return false;
    
    // Ignorar secciones que solo contienen guiones o espacios
    if (/^[-\s]*$/.test(text)) return false;
    
    return true;
}

/**
 * Limpia y formatea el contenido principal
 */
function cleanMainContent(content) {
    return content
        // Eliminar múltiples saltos de línea consecutivos
        .replace(/\n\s*\n\s*\n/g, '\n\n')
        // Eliminar espacios al final de las líneas
        .replace(/[ \t]+$/gm, '')
        // Eliminar líneas que solo contienen espacios
        .replace(/^\s*$/gm, '')
        // Normalizar <br/> tags
        .replace(/<br\s*\/?>/gi, '\n')
        // Limpiar espacios múltiples
        .replace(/  +/g, ' ')
        // Eliminar saltos de línea al inicio y final
        .trim();
}

/**
 * Función auxiliar para formatear múltiples mensajes
 */
function formatMessages(messages) {
    if (!Array.isArray(messages)) {
        return formatMessage(messages);
    }
    
    return messages.map((message, index) => ({
        index,
        ...formatMessage(message)
    }));
}

/**
 * Función de ejemplo/demo
 */
function demoFormatter() {
    const ejemplo1 = "CIERRES<br/><br/>SOL 172.21<br/>ETH 3259\n-- César Langreo\n \n  https://youtu.be/\n  \n  \n \n  https://www.youtube.com/playlist?list=\n  \n  \n \n  \n \nhttps://www.youtube.com/post/Ugkx7qG0Gk6OgBGZW6nKsza9jAJy8y4LJBhN?feature=em-sponsor\n \n---\nUnsubscribe link:  \nhttps://www.youtube.com/email_unsubscribe?uid=AU2xr1k3byiUThxR4YFLzQLb4GM_8VZC5w6t-8nrj2W9S5CPtQFRUhy8e5mG&action_unsubscribe=members_only_posts&timestamp=1752683764&feature=em-sponsor\n© 2025 YouTube, LLC 901 Cherry Ave, San Bruno, CA 94066\n";

    const ejemplo2 = "ORDEN‼️‼️‼️‼️<br/><br/><br/>🚨LONG BTC 119811\n<br/>🐍STOP BTC 118450\n<br/>⚡️APALANCAMIENTO X25\n<br/>🕯️2000USDT<br/><br/><br/>🚨LONG ETH 3353\n<br/>🐍STOP ETH BINGX 3310\n<br/>⚡️APALANCAMIENTO X25\n<br/>🕯️1500USDT<br/><br/><br/>🚨LONG SOL 174.2\n<br/>🐍STOP SOL BINGX 172\n<br/>⚡️APALANCAMIENTO X25\n<br/>🕯️1500USDT<br/><br/>\n<br/>\n<br/>RECORDAD QUE OPERAMOS TODOS EN BINGX Y QUE LOS STOPS SON PARA BI\n-- César Langreo\n \n  https://youtu.be/\n  \n  \n \n  https://www.youtube.com/playlist?list=\n  \n  \n \n  \n \nhttps://www.youtube.com/post/UgkxzAKGi1N39HrDdKmRUXJeKeTxWvlox9MS?feature=em-sponsor\n \n---\nUnsubscribe link:  \nhttps://www.youtube.com/email_unsubscribe?uid=AU2xr1n8wXfqsdD-N7Qsr6rZ8HDaXnHAoVB79RM-nk3bmBTNyhs8FoloFUNU&action_unsubscribe=members_only_posts&timestamp=1752691577&feature=em-sponsor\n© 2025 YouTube, LLC 901 Cherry Ave, San Bruno, CA 94066\n";

    console.log('=== EJEMPLO 1 ===');
    const resultado1 = formatMessage(ejemplo1);
    console.log('Resultado:', resultado1);
    console.log('Mensaje formateado:\n', resultado1.formattedMessage);
    
    console.log('\n=== EJEMPLO 2 ===');
    const resultado2 = formatMessage(ejemplo2);
    console.log('Resultado:', resultado2);
    console.log('Mensaje formateado:\n', resultado2.formattedMessage);
}

// Exportar funciones si estamos en un entorno de módulos
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        formatMessage,
        formatMessages,
        demoFormatter
    };
}

// Ejecutar demo si el script se ejecuta directamente
if (typeof window === 'undefined' && typeof process !== 'undefined') {
    demoFormatter();
} 