package counter

import "strconv"

// On définit un type pour le stockage
type Counter struct {
	Value int
}

// On initialise l'instance
var c Counter

// La fonction publique que tu appelles
func Increment() {
	c.Inc()
}

// La méthode qui fait le travail (c'est elle qui va "laver" le taint)
func (c *Counter) Inc() {
	c.Value++
}

func Render(path string) string {
	return "Compteur Samourai : " + strconv.Itoa(c.Value)
}
