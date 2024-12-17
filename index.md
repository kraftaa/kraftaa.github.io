---
layout: default
title: "A blog about Rust, tech and data engineering."
---

<div class="container">
  <!-- Left column: Contact Info -->
  <div class="left">
    <h2>Contact Info</h2>
    <ul>
      <li><img src="{{ "/assets/images/mypic.png" | relative_url }}" alt="Maria Dubyaga" class="profile-pic"></li>
      <li><a href="https://www.linkedin.com/in/maria-dubyaga-4aa1a73/" target="_blank">LinkedIn</a></li>
      <li><a href="https://github.com/kraftaa" target="_blank">GitHub</a></li>
      <!-- Add more contacts here -->
    </ul>
  </div>

  <!-- Right column: Posts -->
  <div class="right">

    <h2>All Posts</h2>
    <ul>
      {% for post in site.posts %}
        <li><a href="{{ post.url }}">{{ post.title }}</a> - {{ post.date | date: "%B %d, %Y" }}</li>
      {% endfor %}
    </ul>
  </div>
</div>

<!-- Hamburger Menu Toggle -->
<div class="hamburger-menu" onclick="toggleMenu()">☰</div>

<script>
  // Function to toggle the left column (Contact Info)
  function toggleMenu() {
    var leftColumn = document.querySelector('.left');
    leftColumn.classList.toggle('hidden');
  }
</script>
